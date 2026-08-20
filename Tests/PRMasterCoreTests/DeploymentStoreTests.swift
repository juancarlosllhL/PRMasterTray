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
    private let tagReleases: [String: [Release]]
    /// Which call the tag lookup starts refusing on. `0` refuses from the first,
    /// `1` answers once and then refuses — which is how "a version identified
    /// once survives a later failure" is set up.
    private let tagsFailFrom: Int?
    private var _discovered: [String] = []
    private var _promotionCalls = 0
    private var _tagRequests: [[ReleaseTagRequest]] = []

    init(
        found: [AppLocation] = [widgets],
        versions: [AppLocation: [PromotedVersion]] = [:],
        tagReleases: [String: [Release]] = [:],
        discoverFails: Bool = false,
        promotionsFail: Bool = false,
        tagsFailFrom: Int? = nil
    ) {
        self.found = found
        self.versions = versions
        self.tagReleases = tagReleases
        self.discoverFails = discoverFails
        self.promotionsFail = promotionsFail
        self.tagsFailFrom = tagsFailFrom
    }

    var discovered: [String] { lock.withLock { _discovered } }
    var promotionCalls: Int { lock.withLock { _promotionCalls } }
    /// One entry per call, so both "asked once" and "asked for what" can be read.
    var tagRequests: [[ReleaseTagRequest]] { lock.withLock { _tagRequests } }

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

    func releases(forTags requests: [ReleaseTagRequest]) async throws -> [String: [Release]] {
        let calls = lock.withLock { () -> Int in
            let previous = _tagRequests.count
            _tagRequests.append(requests)
            return previous
        }
        if let tagsFailFrom, calls >= tagsFailFrom { throw DeploymentFailure() }
        return tagReleases
    }
}

/// Holds the promotions lookup open until the test lets it go, so "the list did
/// not wait" can be asserted rather than raced.
private final class GatedDeploymentClient: DeploymentFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let versions: [AppLocation: [PromotedVersion]]
    private var waiting: CheckedContinuation<Void, Never>?
    private var entering: CheckedContinuation<Void, Never>?
    private var opened = false
    private var hasEntered = false
    private var _calls = 0

    init(versions: [AppLocation: [PromotedVersion]]) {
        self.versions = versions
    }

    var calls: Int { lock.withLock { _calls } }

    func discover(repo: String) async throws -> [AppLocation] { [widgets] }

    /// Returns once the lookup has actually started.
    ///
    /// Without this, "a second poll while one is in flight" is only ever a
    /// guess about whether the detached task got a turn on the main actor
    /// before the assertion ran — which is a coin toss, not a test.
    func waitUntilCalled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = lock.withLock { () -> Bool in
                if hasEntered { return true }
                entering = continuation
                return false
            }
            if already { continuation.resume() }
        }
    }

    func promotions(for locations: [AppLocation]) async throws -> [AppLocation: [PromotedVersion]] {
        let announce = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            _calls += 1
            hasEntered = true
            defer { entering = nil }
            return entering
        }
        announce?.resume()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = lock.withLock { () -> Bool in
                if opened { return true }
                waiting = continuation
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
        return versions
    }

    func releases(forTags requests: [ReleaseTagRequest]) async throws -> [String: [Release]] {
        [:]
    }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

private func promoted(_ environment: DeployEnvironment, _ region: String, _ version: String) -> PromotedVersion {
    PromotedVersion(
        file: PromotionFile(environment: environment, region: region),
        version: version
    )
}

private func release(_ tag: String, createdAt: Date) -> Release {
    Release(
        tagName: tag,
        url: URL(string: "https://github.com/acme/widget-service/releases/tag/\(tag)")!,
        tagCommitOid: "ffff",
        createdAt: createdAt
    )
}

/// Records the containment questions the store asks, which is how "the release
/// identified from a promoted version reaches the comparison" is read.
private final class SpyShipmentClient: ShipmentFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: Bool?
    private var _asked: [[ContainmentCandidate]] = []

    /// - Parameter answer: given for every candidate. `nil` answers none, which
    ///   is what an environment with no answer yet looks like.
    init(answer: Bool? = nil) {
        self.answer = answer
    }

    var asked: [[ContainmentCandidate]] { lock.withLock { _asked } }

    /// None: the point of these tests is the releases the depth never reaches.
    func fetchReleases(repoIDs: [String], depth: Int) async throws -> [String: [Release]] { [:] }

    func resolveContainment(
        _ candidates: [ContainmentCandidate]
    ) async throws -> [ContainmentKey: Bool] {
        lock.withLock { _asked.append(candidates) }
        guard let answer else { return [:] }
        return candidates.reduce(into: [:]) { $0[$1.key] = answer }
    }
}

@Suite("PRStore deployments")
@MainActor
struct DeploymentStoreTests {

    private func makeStore(
        merged: [MergedPullRequest] = [mergedPR("PR_1")],
        deploymentClient: DeploymentFetching?,
        shipmentClient: ShipmentFetching? = nil,
        preferences: MemoryPreferences = MemoryPreferences()
    ) -> PRStore {
        PRStore(
            client: onlyMerged(merged),
            notifier: QuietNotifier(),
            idStore: NoIDStore(),
            shipmentClient: shipmentClient,
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
        await store.awaitPromotions()

        #expect(store.lastDeploymentFailure != nil)
        #expect(store.lastError == nil)
        #expect(store.shipments.count == 1)
        #expect(store.shipments.first?.environments.isEmpty == true)
    }

    @Test("a failing discovery is reported without taking the rows down")
    func discoveryFailureIsIsolated() async {
        let store = makeStore(deploymentClient: SpyDeploymentClient(discoverFails: true))

        await store.refresh()
        await store.awaitPromotions()

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
        await store.awaitPromotions()
        #expect(store.shipments.first?.environments.isEmpty == false)

        // A second store standing in for the next poll, with the lookup refusing.
        let failing = SpyDeploymentClient(promotionsFail: true)
        let next = makeStore(deploymentClient: failing, preferences: preferences)
        await next.refresh()
        await next.awaitPromotions()
        await next.refresh()
        await next.awaitPromotions()

        #expect(next.lastDeploymentFailure != nil)
    }

    @Test("a successful lookup clears a previous failure")
    func successClearsFailure() async {
        let store = makeStore(
            deploymentClient: SpyDeploymentClient(versions: [widgets: [promoted(.staging, "euw1", "3.32.0")]])
        )
        await store.refresh()
        await store.awaitPromotions()
        #expect(store.lastDeploymentFailure == nil)
    }

    // MARK: the list does not wait

    /// The point of the change. On a cold cache the lookup is a code search plus
    /// a read per hit, and the popover used to sit empty for all of it to say
    /// something the rows do not depend on.
    @Test("the rows are ready before the deployments lookup finishes")
    func listDoesNotWaitForDeployments() async {
        let gate = GatedDeploymentClient(versions: [widgets: [promoted(.staging, "euw1", "3.32.0")]])
        let store = makeStore(deploymentClient: gate)

        await store.refresh()

        // The lookup is still held open, and the row is already here.
        #expect(store.shipments.count == 1)
        #expect(store.shipments.first?.environments.isEmpty == true)

        gate.open()
        await store.awaitPromotions()

        // And the chips arrived on their own, with no second poll.
        #expect(store.shipments.first?.environments.isEmpty == false)
    }

    /// A poll arriving while the previous lookup is still out must not start a
    /// second one: on a cold cache that would spend a rate-limited code search
    /// per poll to learn the same thing.
    @Test("a poll during a lookup does not start a second one")
    func lookupsDoNotPileUp() async {
        let gate = GatedDeploymentClient(versions: [:])
        let store = makeStore(deploymentClient: gate)

        await store.refresh()
        // Waited for rather than assumed: the lookup has provably started and is
        // held open, so the polls below genuinely arrive during one.
        await gate.waitUntilCalled()

        await store.refresh()
        await store.refresh()
        #expect(gate.calls == 1)

        gate.open()
        await store.awaitPromotions()
    }

    /// Switching the section off while a lookup is in the air must not let its
    /// answer put chips back afterwards.
    @Test("switching the window off cancels the lookup in flight")
    func windowOffCancelsInFlight() async {
        let gate = GatedDeploymentClient(versions: [widgets: [promoted(.staging, "euw1", "3.32.0")]])
        let store = makeStore(deploymentClient: gate)

        await store.refresh()
        store.mergedWindow = .off
        gate.open()
        await store.awaitPromotions()

        #expect(store.shipments.isEmpty)
    }

    /// A row with no chips and a lookup still running is not the same thing as a
    /// repository that deploys nowhere, and the two look identical without this.
    @Test("the lookup is flagged while it runs and cleared when it lands")
    func loadingIsFlagged() async {
        let gate = GatedDeploymentClient(versions: [widgets: [promoted(.staging, "euw1", "3.32.0")]])
        let store = makeStore(deploymentClient: gate)

        await store.refresh()
        #expect(store.isLoadingDeployments)

        gate.open()
        await store.awaitPromotions()
        #expect(store.isLoadingDeployments == false)
    }

    /// Including when it found nothing: an indicator that never stops is worse
    /// than one that never starts.
    @Test("a lookup that fails still clears the indicator")
    func loadingClearsOnFailure() async {
        let store = makeStore(deploymentClient: SpyDeploymentClient(promotionsFail: true))

        await store.refresh()
        await store.awaitPromotions()

        #expect(store.isLoadingDeployments == false)
    }

    @Test("a cancelled lookup clears the indicator rather than leaving it spinning")
    func loadingClearsOnCancellation() async {
        let gate = GatedDeploymentClient(versions: [:])
        let store = makeStore(deploymentClient: gate)

        await store.refresh()
        store.mergedWindow = .off

        #expect(store.isLoadingDeployments == false)
        gate.open()
    }

    @Test("no deployments client never raises the indicator")
    func noClientNeverLoads() async {
        let store = makeStore(deploymentClient: nil)

        await store.refresh()

        #expect(store.isLoadingDeployments == false)
    }

    // MARK: discovery happens once

    @Test("a repository is searched once across two refreshes")
    func discoveryHappensOnce() async {
        let spy = SpyDeploymentClient()
        let store = makeStore(deploymentClient: spy)

        await store.refresh()
        await store.awaitPromotions()
        await store.refresh()
        await store.awaitPromotions()

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
        await store.awaitPromotions()
        await store.refresh()
        await store.awaitPromotions()

        #expect(spy.discovered == ["acme/widget-service"])
    }

    @Test("a discovered mapping is persisted and reused by the next launch")
    func mappingSurvivesRelaunch() async {
        let preferences = MemoryPreferences()
        let first = SpyDeploymentClient()
        let firstStore = makeStore(deploymentClient: first, preferences: preferences)
        await firstStore.refresh()
        await firstStore.awaitPromotions()
        #expect(preferences.appLocations() == ["acme/widget-service": [widgets]])

        let second = SpyDeploymentClient()
        let secondStore = makeStore(deploymentClient: second, preferences: preferences)
        await secondStore.refresh()
        await secondStore.awaitPromotions()
        #expect(second.discovered.isEmpty)
    }

    /// Written back only when something new was found, so a poll that discovered
    /// nothing does not rewrite the same map.
    @Test("an unchanged mapping is not written back on every poll")
    func mappingIsNotRewritten() async {
        let preferences = MemoryPreferences()
        let store = makeStore(deploymentClient: SpyDeploymentClient(), preferences: preferences)

        await store.refresh()
        await store.awaitPromotions()
        await store.refresh()
        await store.awaitPromotions()

        #expect(preferences.appLocationWrites == 1)
    }

    // MARK: nothing to do

    @Test("nothing merged means no discovery and no promotions call")
    func nothingMergedAsksNothing() async {
        let spy = SpyDeploymentClient()
        let store = makeStore(merged: [], deploymentClient: spy)

        await store.refresh()
        await store.awaitPromotions()

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
        await store.awaitPromotions()

        #expect(spy.discovered.isEmpty)
        #expect(spy.promotionCalls == 0)
        #expect(store.shipments.isEmpty)
    }

    @Test("no deployments client means no environments and no failure")
    func noClientIsNotAFailure() async {
        let store = makeStore(deploymentClient: nil)

        await store.refresh()
        await store.awaitPromotions()

        #expect(store.lastDeploymentFailure == nil)
        #expect(store.shipments.first?.environments.isEmpty == true)
    }

    // MARK: an environment lagging past the fetched depth

    /// The chips production never had. Its version is many releases behind, so
    /// the window's depth never reaches it, and a version nothing identifies is
    /// silently no chip at all rather than a lag.
    @Test("a promoted version outside the fetched releases is identified and reported")
    func laggingVersionIsIdentified() async {
        let spy = SpyDeploymentClient(
            versions: [widgets: [promoted(.production, "euw1", "3.31.1")]],
            tagReleases: ["R_1": [release("v3.31.1", createdAt: pollTime.addingTimeInterval(-1_200))]]
        )
        let store = makeStore(deploymentClient: spy)

        await store.refresh()
        await store.awaitPromotions()

        #expect(spy.tagRequests == [[
            ReleaseTagRequest(repo: "acme/widget-service", repositoryID: "R_1", version: "3.31.1")
        ]])
        // Cut before the merge, so the clock settles it without a comparison.
        #expect(store.shipments.first?.environments == [
            EnvironmentState(environment: .production, status: .awaiting(version: "3.31.1"))
        ])
    }

    /// Identified once and then in hand: re-asking every minute would spend a
    /// request all day to be told the same tag.
    @Test("a version already identified is not asked about again")
    func identifiedVersionIsNotReAsked() async {
        let spy = SpyDeploymentClient(
            versions: [widgets: [promoted(.production, "euw1", "3.31.1")]],
            tagReleases: ["R_1": [release("v3.31.1", createdAt: pollTime.addingTimeInterval(-1_200))]]
        )
        let store = makeStore(deploymentClient: spy)

        await store.refresh()
        await store.awaitPromotions()
        await store.refresh()
        await store.awaitPromotions()

        #expect(spy.tagRequests.count == 1)
    }

    @Test("a failing tag lookup is reported without taking the rows down")
    func tagFailureIsIsolated() async {
        let spy = SpyDeploymentClient(
            versions: [widgets: [promoted(.production, "euw1", "3.31.1")]],
            tagsFailFrom: 0
        )
        let store = makeStore(deploymentClient: spy)

        await store.refresh()
        await store.awaitPromotions()

        #expect(store.lastDeploymentFailure != nil)
        #expect(store.lastError == nil)
        #expect(store.shipments.count == 1)
    }

    /// Yesterday's answer beats no answer here too: a flap must not blank a chip
    /// that was right a minute ago.
    @Test("a version identified once survives a later failure")
    func identifiedVersionSurvivesFailure() async {
        let spy = SpyDeploymentClient(
            versions: [widgets: [promoted(.production, "euw1", "3.31.1")]],
            tagReleases: ["R_1": [release("v3.31.1", createdAt: pollTime.addingTimeInterval(-1_200))]],
            tagsFailFrom: 1
        )
        let store = makeStore(deploymentClient: spy)

        let awaiting = [
            EnvironmentState(environment: .production, status: .awaiting(version: "3.31.1"))
        ]

        await store.refresh()
        await store.awaitPromotions()
        #expect(store.shipments.first?.environments == awaiting)

        // The second poll would refuse — but the version is in hand, so it is
        // never asked, and the chip stands.
        await store.refresh()
        await store.awaitPromotions()

        #expect(store.shipments.first?.environments == awaiting)
        #expect(store.lastDeploymentFailure == nil)
    }

    /// A release the environment is on that was cut *after* the merge is a real
    /// containment question, and identifying it is what puts it in front of the
    /// comparison at all. The answer arrives on the following poll, which is the
    /// one lag this accepts.
    @Test("a release identified from a promoted version becomes a containment candidate")
    func identifiedReleaseIsCompared() async {
        let shipments = SpyShipmentClient()
        let spy = SpyDeploymentClient(
            versions: [widgets: [promoted(.staging, "euw1", "3.40.0")]],
            tagReleases: ["R_1": [release("v3.40.0", createdAt: pollTime.addingTimeInterval(-300))]]
        )
        let store = makeStore(deploymentClient: spy, shipmentClient: shipments)

        await store.refresh()
        await store.awaitPromotions()
        // Nothing to compare yet: the release was not in hand when this poll's
        // candidates were worked out.
        #expect(shipments.asked.flatMap { $0 }.isEmpty)

        await store.refresh()
        await store.awaitPromotions()

        #expect(shipments.asked.last?.map(\.release.tagName) == ["v3.40.0"])
    }

    /// The green half, end to end: identified from the promoted version, compared
    /// on the next poll, and only then coloured — by the comparison, never by the
    /// version being higher.
    @Test("an identified release carrying the merge turns the chip green")
    func identifiedReleaseCanCarry() async {
        let shipments = SpyShipmentClient(answer: true)
        let spy = SpyDeploymentClient(
            versions: [widgets: [promoted(.staging, "euw1", "3.40.0")]],
            tagReleases: ["R_1": [release("v3.40.0", createdAt: pollTime.addingTimeInterval(-300))]]
        )
        let store = makeStore(deploymentClient: spy, shipmentClient: shipments)

        await store.refresh()
        await store.awaitPromotions()
        await store.refresh()
        await store.awaitPromotions()

        #expect(store.shipments.first?.environments == [
            EnvironmentState(environment: .staging, status: .carrying(version: "3.40.0"))
        ])
    }

    /// Pruned with the rows they belonged to, or a long-running app would keep
    /// every release it has ever identified.
    @Test("identified releases are dropped when the section empties")
    func identifiedReleasesArePruned() async {
        let spy = SpyDeploymentClient(
            versions: [widgets: [promoted(.production, "euw1", "3.31.1")]],
            tagReleases: ["R_1": [release("v3.31.1", createdAt: pollTime.addingTimeInterval(-1_200))]]
        )
        let store = makeStore(deploymentClient: spy)

        await store.refresh()
        await store.awaitPromotions()
        #expect(spy.tagRequests.count == 1)

        store.mergedWindow = .off
        await store.refresh()
        await store.awaitPromotions()
        #expect(store.shipments.isEmpty)

        store.mergedWindow = .oneDay
        await store.refresh()
        await store.awaitPromotions()

        // Asked again, because nothing identified for an empty section was kept.
        #expect(spy.tagRequests.count == 2)
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
