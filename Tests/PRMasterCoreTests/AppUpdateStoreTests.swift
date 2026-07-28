import Foundation
import Testing
@testable import PRMasterCore

private func makeRelease(_ tag: String, sha256: String? = "sha256:abc") -> AppRelease {
    AppRelease(
        tag: tag,
        assetURL: URL(string: "https://example.com/PRMaster.app.zip")!,
        sha256: sha256
    )
}

/// Serves a scripted sequence of results, one per check.
private final class StubChecker: ReleaseChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<AppRelease, PRMasterError>]
    private var _calls = 0

    var calls: Int { lock.withLock { _calls } }

    init(_ results: [Result<AppRelease, PRMasterError>]) { self.results = results }

    func fetchLatestRelease() async throws -> AppRelease {
        // A real fetch suspends. Yielding here is what lets the reentrancy
        // guard be observed rather than optimised away.
        await Task.yield()
        let next: Result<AppRelease, PRMasterError> = lock.withLock {
            _calls += 1
            return results.isEmpty ? .failure(.noReleaseYet) : results.removeFirst()
        }
        return try next.get()
    }
}

private struct InstallFailure: Error, LocalizedError {
    var errorDescription: String? { "the copy was refused" }
}

private final class SpyInstaller: AppUpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _installed: [String] = []
    private let failing: Bool

    init(failing: Bool = false) { self.failing = failing }

    var installed: [String] { lock.withLock { _installed } }

    func install(_ release: AppRelease) async throws {
        lock.withLock { _installed.append(release.tag) }
        if failing { throw InstallFailure() }
    }
}

/// Counts sleeps so the poll loop can be driven without waiting on real time.
private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    var durations: [Duration] { lock.withLock { _durations } }
    func record(_ d: Duration) -> Int {
        lock.withLock { _durations.append(d); return _durations.count }
    }
}

@MainActor
private func makeStore(
    _ results: [Result<AppRelease, PRMasterError>],
    currentVersion: String = "0.1.0",
    installer: AppUpdateInstalling? = nil,
    interval: Duration = .seconds(1800),
    sleep: (@Sendable (Duration) async throws -> Void)? = nil
) -> (store: AppUpdateStore, checker: StubChecker) {
    let checker = StubChecker(results)
    let store = AppUpdateStore(
        checker: checker,
        currentVersion: currentVersion,
        installer: installer,
        interval: interval,
        sleep: sleep ?? { _ in }
    )
    return (store, checker)
}

@Suite("App update store")
@MainActor
struct AppUpdateStoreTests {

    // MARK: deciding whether an update exists

    @Test("a newer release becomes available")
    func newerReleaseIsOffered() async {
        let ctx = makeStore([.success(makeRelease("v0.2.0"))], currentVersion: "0.1.0")
        await ctx.store.checkNow()

        #expect(ctx.store.availableRelease?.version == "0.2.0")
        #expect(ctx.store.lastCheckFailure == nil)
    }

    /// Offering the build the user is already running would make the row
    /// permanent and the Update button a no-op.
    @Test("the running version is not offered", arguments: ["0.1.0", "0.0.9", "0.1"])
    func sameOrOlderIsNotOffered(tag: String) async {
        let ctx = makeStore([.success(makeRelease("v\(tag)"))], currentVersion: "0.1.0")
        await ctx.store.checkNow()

        #expect(ctx.store.availableRelease == nil)
    }

    /// A release that was newer and then got yanked must stop being offered,
    /// rather than leaving a row pointing at an asset that no longer exists.
    @Test("an offer is withdrawn when a later check no longer sees it")
    func offerIsWithdrawn() async {
        let ctx = makeStore(
            [.success(makeRelease("v0.2.0")), .success(makeRelease("v0.1.0"))],
            currentVersion: "0.1.0"
        )
        await ctx.store.checkNow()
        #expect(ctx.store.availableRelease != nil)

        await ctx.store.checkNow()
        #expect(ctx.store.availableRelease == nil)
    }

    // MARK: failures

    /// The state this repo is in before its first release. Surfacing a warning
    /// row would tell the user something is broken when nothing is.
    @Test("no release yet is silent")
    func noReleaseYetIsSilent() async {
        let ctx = makeStore([.failure(.noReleaseYet)])
        await ctx.store.checkNow()

        #expect(ctx.store.availableRelease == nil)
        #expect(ctx.store.lastCheckFailure == nil)
    }

    @Test("a real failure is surfaced", arguments: [
        PRMasterError.network(URLError(.notConnectedToInternet)),
        .releaseCheckFailed("GitHub returned 503"),
        .releaseAssetMissing,
    ])
    func realFailuresAreSurfaced(error: PRMasterError) async {
        let ctx = makeStore([.failure(error)])
        await ctx.store.checkNow()

        #expect(ctx.store.lastCheckFailure == error.localizedDescription)
    }

    /// Otherwise a single flap would leave a warning row on screen forever.
    @Test("a later success clears an earlier failure")
    func successClearsFailure() async {
        let ctx = makeStore([
            .failure(.network(URLError(.timedOut))),
            .success(makeRelease("v0.2.0")),
        ])
        await ctx.store.checkNow()
        #expect(ctx.store.lastCheckFailure != nil)

        await ctx.store.checkNow()
        #expect(ctx.store.lastCheckFailure == nil)
        #expect(ctx.store.availableRelease?.version == "0.2.0")
    }

    /// A failed check must not retract a release already found: the popover
    /// would drop the Update button because the network blipped.
    @Test("a failed check keeps a release already found")
    func failureKeepsExistingOffer() async {
        let ctx = makeStore([
            .success(makeRelease("v0.2.0")),
            .failure(.network(URLError(.timedOut))),
        ])
        await ctx.store.checkNow()
        await ctx.store.checkNow()

        #expect(ctx.store.availableRelease?.version == "0.2.0")
        #expect(ctx.store.lastCheckFailure != nil)
    }

    // MARK: reentrancy

    /// The gear's manual check and the poll loop can both land here. MainActor
    /// methods are reentrant across `await`, so without a guard two overlapping
    /// checks would both run and the slower one would win.
    @Test("overlapping checks collapse into one")
    func checkIsNotReentrant() async {
        let ctx = makeStore([.success(makeRelease("v0.2.0")), .success(makeRelease("v0.3.0"))])

        async let first: Void = ctx.store.checkNow()
        async let second: Void = ctx.store.checkNow()
        _ = await (first, second)

        #expect(ctx.checker.calls == 1)
        #expect(!ctx.store.isChecking)
    }

    // MARK: the poll loop

    @Test("the loop checks, waits the interval, and repeats")
    func pollLoopHonoursInterval() async {
        let log = SleepLog()
        let ctx = makeStore(
            [.success(makeRelease("v0.2.0")), .success(makeRelease("v0.2.0"))],
            interval: .seconds(1800),
            sleep: { duration in
                // Ends the loop rather than waiting on real time.
                if log.record(duration) >= 2 { throw CancellationError() }
            }
        )

        await ctx.store.pollLoop()

        #expect(ctx.checker.calls == 2)
        #expect(log.durations == [.seconds(1800), .seconds(1800)])
    }

    // MARK: installing

    /// `nil` is the hard kill switch the app passes under a debug override, so
    /// it has to be visible to the UI and not merely fail on click.
    @Test("no installer means the app cannot offer to install")
    func nilInstallerCannotInstall() async {
        let ctx = makeStore([.success(makeRelease("v0.2.0"))], installer: nil)
        await ctx.store.checkNow()
        #expect(!ctx.store.canInstall)

        await ctx.store.install()
        #expect(ctx.store.lastInstallFailure == nil, "a refusal is not a failure to report")
    }

    @Test("installing hands the available release to the installer")
    func installsAvailableRelease() async {
        let spy = SpyInstaller()
        let ctx = makeStore([.success(makeRelease("v0.2.0"))], installer: spy)
        await ctx.store.checkNow()

        await ctx.store.install()

        #expect(spy.installed == ["v0.2.0"])
        #expect(ctx.store.canInstall)
    }

    @Test("installing without an available release does nothing")
    func installNeedsARelease() async {
        let spy = SpyInstaller()
        let ctx = makeStore([.failure(.noReleaseYet)], installer: spy)
        await ctx.store.checkNow()

        await ctx.store.install()

        #expect(spy.installed.isEmpty)
    }

    /// A successful install never returns — the process is replaced. A failed
    /// one has to hand the popover back in a usable state, with the offer
    /// intact so the user can try again.
    @Test("a failed install is reported and leaves the offer standing")
    func failedInstallIsReported() async {
        let spy = SpyInstaller(failing: true)
        let ctx = makeStore([.success(makeRelease("v0.2.0"))], installer: spy)
        await ctx.store.checkNow()

        await ctx.store.install()

        #expect(ctx.store.lastInstallFailure == "the copy was refused")
        #expect(!ctx.store.isInstalling)
        #expect(ctx.store.availableRelease?.version == "0.2.0")
    }
}
