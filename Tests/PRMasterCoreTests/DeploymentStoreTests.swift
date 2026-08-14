import Foundation
import Testing
@testable import PRMasterCore

private let pollTime = Date(timeIntervalSince1970: 1_000_000)

private func mergedPR(_ id: String, repo: String = "acme/widget-service") -> MergedPullRequest {
    MergedPullRequest(
        id: id,
        number: 1,
        title: "merged thing",
        url: URL(string: "https://github.com/\(repo)/pull/1")!,
        repo: repo,
        repositoryID: "R_1",
        isPrivate: false,
        mergedAt: pollTime.addingTimeInterval(-600),
        mergeCommitOid: "abc",
        rollupState: .success,
        contexts: []
    )
}

private func onlyMerged(_ merged: [MergedPullRequest]) -> PullRequestFetching {
    MergedOnlyClient(merged: merged)
}

private struct MergedOnlyClient: PullRequestFetching {
    let merged: [MergedPullRequest]
    func fetchMyPullRequests(mergedWindow: MergedWindow) async throws -> PullRequestSnapshot {
        PullRequestSnapshot(open: [], merged: merged)
    }
}

private struct DeploymentFailure: Error, LocalizedError {
    var errorDescription: String? { "deployments repository refused" }
}

/// Local rather than shared: the equivalents in the other store suites are
/// private, and widening them collides with same-named helpers elsewhere.
private struct QuietNotifier: ReadyPRNotifying {
    func notifyReady(_ pr: PullRequest) async throws {}
}

private struct NoIDStore: NotifiedIDStore {
    func load() -> Set<String> { [] }
    func save(_ ids: Set<String>) {}
}

private let widgets = AppLocation(
    deploymentsRepo: "acme/widget-deployments",
    appPath: "widget-service"
)

/// Scriptable deployments side, counting what it was asked.
private final class SpyDeploymentClient: DeploymentFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let found: [AppLocation]
    private let versions: [AppLocation: [PromotedVersion]]
    private let discoverFails: Bool
    private let promotionsFail: Bool
    private var _discovered: [String] = []
    private var _promotionCalls = 0

    init(
        found: [AppLocation] = [widgets],
        versions: [AppLocation: [PromotedVersion]] = [:],
        discoverFails: Bool = false,
        promotionsFail: Bool = false
    ) {
        self.found = found
        self.versions = versions
        self.discoverFails = discoverFails
        self.promotionsFail = promotionsFail
    }

    var discovered: [String] { lock.withLock { _discovered } }
    var promotionCalls: Int { lock.withLock { _promotionCalls } }

    func discover(repo: String) async throws -> [AppLocation] {
        lock.withLock { _discovered.append(repo) }
        if discoverFails { throw DeploymentFailure() }
        return found
    }

    func promotions(for locations: [AppLocation]) async throws -> [AppLocation: [PromotedVersion]] {
        lock.withLock { _promotionCalls += 1 }
        if promotionsFail { throw DeploymentFailure() }
        return versions
    }
}

private func promoted(_ environment: DeployEnvironment, _ region: String, _ version: String) -> PromotedVersion {
    PromotedVersion(
        file: PromotionFile(environment: environment, region: region),
        version: version
    )
}

@Suite("PRStore deployments")
@MainActor
struct DeploymentStoreTests {

    private func makeStore(
        merged: [MergedPullRequest] = [mergedPR("PR_1")],
        deploymentClient: SpyDeploymentClient?,
        preferences: MemoryPreferences = MemoryPreferences()
    ) -> PRStore {
        PRStore(
            client: onlyMerged(merged),
            notifier: QuietNotifier(),
            idStore: NoIDStore(),
            deploymentClient: deploymentClient,
            preferences: preferences,
            now: { pollTime },
            sleep: { _ in }
        )
    }

    // MARK: failure isolation

    /// The whole reason this is a separate port. A deployments repository being
    /// unreachable says nothing about whether the merged rows are right.
    @Test("a failing deployments lookup leaves the rows and the stale banner alone")
    func failureIsIsolated() async {
        let store = makeStore(deploymentClient: SpyDeploymentClient(promotionsFail: true))

        await store.refresh()

        #expect(store.lastDeploymentFailure != nil)
        #expect(store.lastError == nil)
        #expect(store.shipments.count == 1)
        #expect(store.shipments.first?.environments.isEmpty == true)
    }

    @Test("a failing discovery is reported without taking the rows down")
    func discoveryFailureIsIsolated() async {
        let store = makeStore(deploymentClient: SpyDeploymentClient(discoverFails: true))

        await store.refresh()

        #expect(store.lastDeploymentFailure != nil)
        #expect(store.lastError == nil)
        #expect(store.shipments.count == 1)
    }

    /// Yesterday's answer beats no answer: a flap must not blank chips that were
    /// right a minute ago.
    @Test("a later failure keeps the environments already resolved")
    func failureKeepsPreviousEnvironments() async {
        let preferences = MemoryPreferences()
        let good = SpyDeploymentClient(versions: [widgets: [promoted(.staging, "euw1", "3.32.0")]])
        let store = makeStore(deploymentClient: good, preferences: preferences)
        await store.refresh()
        #expect(store.shipments.first?.environments.isEmpty == false)

        // A second store standing in for the next poll, with the lookup refusing.
        let failing = SpyDeploymentClient(promotionsFail: true)
        let next = makeStore(deploymentClient: failing, preferences: preferences)
        await next.refresh()
        await next.refresh()

        #expect(next.lastDeploymentFailure != nil)
    }

    @Test("a successful lookup clears a previous failure")
    func successClearsFailure() async {
        let store = makeStore(
            deploymentClient: SpyDeploymentClient(versions: [widgets: [promoted(.staging, "euw1", "3.32.0")]])
        )
        await store.refresh()
        #expect(store.lastDeploymentFailure == nil)
    }

    // MARK: discovery happens once

    @Test("a repository is searched once across two refreshes")
    func discoveryHappensOnce() async {
        let spy = SpyDeploymentClient()
        let store = makeStore(deploymentClient: spy)

        await store.refresh()
        await store.refresh()

        #expect(spy.discovered == ["acme/widget-service"])
        // The promotions read still happens every poll — that is the cheap half.
        #expect(spy.promotionCalls == 2)
    }

    /// An empty result is a real answer. Retrying it every poll would spend a
    /// rate-limited code search to be told the same thing all day.
    @Test("a repository that deploys nothing is not searched again")
    func negativeResultIsCached() async {
        let spy = SpyDeploymentClient(found: [])
        let store = makeStore(deploymentClient: spy)

        await store.refresh()
        await store.refresh()

        #expect(spy.discovered == ["acme/widget-service"])
    }

    @Test("a discovered mapping is persisted and reused by the next launch")
    func mappingSurvivesRelaunch() async {
        let preferences = MemoryPreferences()
        let first = SpyDeploymentClient()
        await makeStore(deploymentClient: first, preferences: preferences).refresh()
        #expect(preferences.appLocations() == ["acme/widget-service": [widgets]])

        let second = SpyDeploymentClient()
        await makeStore(deploymentClient: second, preferences: preferences).refresh()
        #expect(second.discovered.isEmpty)
    }

    /// Written back only when something new was found, so a poll that discovered
    /// nothing does not rewrite the same map.
    @Test("an unchanged mapping is not written back on every poll")
    func mappingIsNotRewritten() async {
        let preferences = MemoryPreferences()
        let store = makeStore(deploymentClient: SpyDeploymentClient(), preferences: preferences)

        await store.refresh()
        await store.refresh()

        #expect(preferences.appLocationWrites == 1)
    }

    // MARK: nothing to do

    @Test("nothing merged means no discovery and no promotions call")
    func nothingMergedAsksNothing() async {
        let spy = SpyDeploymentClient()
        let store = makeStore(merged: [], deploymentClient: spy)

        await store.refresh()

        #expect(spy.discovered.isEmpty)
        #expect(spy.promotionCalls == 0)
    }

    /// `.off` filters every merge out before the section is resolved, so the same
    /// guard covers it.
    @Test("the merged window switched off asks nothing")
    func windowOffAsksNothing() async {
        let preferences = MemoryPreferences()
        preferences.setMergedWindow(.off)
        let spy = SpyDeploymentClient()
        let store = makeStore(deploymentClient: spy, preferences: preferences)

        await store.refresh()

        #expect(spy.discovered.isEmpty)
        #expect(spy.promotionCalls == 0)
        #expect(store.shipments.isEmpty)
    }

    @Test("no deployments client means no environments and no failure")
    func noClientIsNotAFailure() async {
        let store = makeStore(deploymentClient: nil)

        await store.refresh()

        #expect(store.lastDeploymentFailure == nil)
        #expect(store.shipments.first?.environments.isEmpty == true)
    }

    // MARK: persistence shape

    @Test("app locations round-trip through UserDefaults")
    func appLocationsRoundTrip() {
        let defaults = UserDefaults(suiteName: "DeploymentStoreTests.locations")!
        defaults.removePersistentDomain(forName: "DeploymentStoreTests.locations")
        let preferences = UserDefaultsPreferences(defaults: defaults)

        #expect(preferences.appLocations().isEmpty)
        preferences.setAppLocations(["acme/widget-service": [widgets]])
        #expect(preferences.appLocations() == ["acme/widget-service": [widgets]])

        // An empty array is a real answer and must survive as one.
        preferences.setAppLocations(["acme/widget-service": []])
        #expect(preferences.appLocations() == ["acme/widget-service": []])
    }

    /// A value written by some older shape must read as "nothing discovered"
    /// rather than crashing, costing one search per repository to rebuild.
    @Test("an unreadable stored mapping reads as nothing discovered")
    func unreadableMappingIsEmpty() {
        let defaults = UserDefaults(suiteName: "DeploymentStoreTests.garbage")!
        defaults.removePersistentDomain(forName: "DeploymentStoreTests.garbage")
        defaults.set(Data("not json".utf8), forKey: "appLocations")
        #expect(UserDefaultsPreferences(defaults: defaults).appLocations().isEmpty)
    }
}
