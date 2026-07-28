import Foundation
import Observation

/// Replaces the running app with a downloaded release.
///
/// Implemented in the app target: it touches the filesystem, spawns a process
/// and ends the process's life, none of which belong in `PRMasterCore`.
public protocol AppUpdateInstalling: Sendable {
    func install(_ release: AppRelease) async throws
}

/// Observable state behind the popover's update row.
///
/// Kept separate from `PRStore` rather than folded into it: checking for a new
/// build of PRMaster has nothing to do with polling pull requests, runs on a
/// different clock, and must not be able to disturb the PR list when it fails.
@MainActor
@Observable
public final class AppUpdateStore {

    /// The newest release that is actually newer than what is running. `nil`
    /// both before the first check and whenever the app is up to date.
    public private(set) var availableRelease: AppRelease?
    public private(set) var isChecking = false
    public private(set) var isInstalling = false
    /// Set when a check reached GitHub and got something unusable. Surfaced for
    /// the same reason `PRStore.lastUpdateFailure` is: there is no logging in
    /// this app, so a silent failure is invisible.
    public private(set) var lastCheckFailure: String?
    public private(set) var lastInstallFailure: String?

    /// The running app's `CFBundleShortVersionString`. Injected rather than read
    /// here so `PRMasterCore` stays free of `Bundle.main`, which in tests is the
    /// test bundle and not the app.
    public let currentVersion: String

    private let checker: ReleaseChecking
    /// `nil` disables installing outright. The app passes `nil` under any debug
    /// override — the same hard guarantee `PRStore.updater` gives, for a sharper
    /// reason: this path replaces the app's own bundle on disk.
    private let installer: AppUpdateInstalling?
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pollTask: Task<Void, Never>?

    /// False when there is no installer, so the UI never offers a button it is
    /// going to refuse.
    public var canInstall: Bool { installer != nil }

    public init(
        checker: ReleaseChecking,
        currentVersion: String,
        installer: AppUpdateInstalling? = nil,
        // 30 minutes against a 60-per-hour unauthenticated budget. The PR poll
        // runs every 60s; a new build of this app does not appear that often.
        interval: Duration = .seconds(1800),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.checker = checker
        self.currentVersion = currentVersion
        self.installer = installer
        self.interval = interval
        self.sleep = sleep
    }

    // MARK: - Checking

    public func checkNow() async {
        // Two call sites reach here: the poll loop and "Check for Updates…" in
        // the gear. @MainActor methods are reentrant across `await`, so without
        // this the slower of two overlapping checks wins.
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await checker.fetchLatestRelease()
            availableRelease =
                ReleaseVersion.isNewer(release.version, than: currentVersion) ? release : nil
            lastCheckFailure = nil
        } catch PRMasterError.noReleaseYet {
            // Not a fault: it is the state the repo is in until the first tag is
            // pushed. A warning row here would report a problem that is not one.
            availableRelease = nil
            lastCheckFailure = nil
        } catch {
            // `availableRelease` is deliberately untouched. A network flap must
            // not retract an update the user was already being offered.
            lastCheckFailure = error.localizedDescription
        }
    }

    // MARK: - Installing

    /// Replaces the app with `availableRelease`.
    ///
    /// On success this does not return: the installer ends the process. Only a
    /// failure comes back here, and it leaves the offer standing so the user can
    /// try again.
    public func install() async {
        guard !isInstalling, let installer, let release = availableRelease else { return }
        isInstalling = true
        lastInstallFailure = nil

        do {
            try await installer.install(release)
        } catch {
            lastInstallFailure = error.localizedDescription
            isInstalling = false
        }
    }

    // MARK: - Polling

    /// Check, wait, repeat. Exposed for tests so the loop can be driven with an
    /// injected sleep instead of real time.
    func pollLoop() async {
        while !Task.isCancelled {
            await checkNow()
            do {
                try await sleep(interval)
            } catch {
                return  // cancelled
            }
        }
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}
