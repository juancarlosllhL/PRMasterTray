import Foundation
import Testing
@testable import PRMasterCore

private let pollTime = Date(timeIntervalSince1970: 1_000_000)

private func mergedPR(
    _ id: String,
    repo: String = "acme/widget-service",
    repositoryID: String = "R_1",
    isPrivate: Bool = false,
    mergedAt: Date = pollTime.addingTimeInterval(-600),
    oid: String? = "abc"
) -> MergedPullRequest {
    MergedPullRequest(
        id: id,
        number: 1,
        title: "merged thing",
        url: URL(string: "https://github.com/\(repo)/pull/1")!,
        repo: repo,
        repositoryID: repositoryID,
        isPrivate: isPrivate,
        mergedAt: mergedAt,
        mergeCommitOid: oid,
        rollupState: .success,
        contexts: []
    )
}

private func release(_ tag: String) -> Release {
    Release(
        tagName: tag,
        url: URL(string: "https://github.com/acme/widget-service/releases/tag/\(tag)")!,
        tagCommitOid: "zzz",
        createdAt: pollTime.addingTimeInterval(-300)
    )
}

private func openPR(_ id: String) -> PullRequest {
    PullRequest(
        id: id, number: 1, title: "open thing",
        url: URL(string: "https://github.com/acme/widget-service/pull/1")!,
        repo: "acme/widget-service", isPrivate: false, isDraft: false, headRefOid: "oid",
        mergeable: .mergeable, mergeState: .clean,
        reviewDecision: nil, checks: .success, approvals: 0,
        updatedAt: Date(timeIntervalSince1970: 0),
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

/// Serves a scripted open list plus a fixed merged one.
private final class SnapshotClient: PullRequestFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[PullRequest], PRMasterError>]
    private let merged: [MergedPullRequest]

    init(_ results: [Result<[PullRequest], PRMasterError>], merged: [MergedPullRequest]) {
        self.results = results
        self.merged = merged
    }

    func fetchMyPullRequests() async throws -> PullRequestSnapshot {
        let next: Result<[PullRequest], PRMasterError> = lock.withLock {
            results.isEmpty ? .success([]) : results.removeFirst()
        }
        return PullRequestSnapshot(open: try next.get(), merged: merged)
    }
}

private struct ReleaseFailure: Error, LocalizedError {
    var errorDescription: String? { "releases lookup refused" }
}

/// Scriptable shipment side of the client, counting what it was asked.
private final class SpyShipmentClient: ShipmentFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let releases: [String: [Release]]
    private let answers: [ContainmentKey: Bool]
    private let releasesFail: Bool
    private var _containmentAsks: [[ContainmentCandidate]] = []
    private var _releaseCalls = 0

    init(
        releases: [String: [Release]] = [:],
        answers: [ContainmentKey: Bool] = [:],
        releasesFail: Bool = false
    ) {
        self.releases = releases
        self.answers = answers
        self.releasesFail = releasesFail
    }

    var containmentAsks: [[ContainmentCandidate]] { lock.withLock { _containmentAsks } }
    var releaseCalls: Int { lock.withLock { _releaseCalls } }

    func fetchReleases(repoIDs: [String]) async throws -> [String: [Release]] {
        lock.withLock { _releaseCalls += 1 }
        if releasesFail { throw ReleaseFailure() }
        return releases
    }

    func resolveContainment(
        _ candidates: [ContainmentCandidate]
    ) async throws -> [ContainmentKey: Bool] {
        lock.withLock { _containmentAsks.append(candidates) }
        return answers.filter { key, _ in candidates.contains { $0.key == key } }
    }
}

@Suite("PRStore shipments")
@MainActor
struct ShipmentStoreTests {

    private func makeStore(
        open: [Result<[PullRequest], PRMasterError>] = [.success([])],
        merged: [MergedPullRequest] = [],
        shipmentClient: SpyShipmentClient? = SpyShipmentClient(),
        filter: PRFilter = PRFilter()
    ) -> (PRStore, SpyShipmentClient?) {
        let store = PRStore(
            client: SnapshotClient(open, merged: merged),
            notifier: SilentNotifier(),
            idStore: EmptyIDStore(),
            shipmentClient: shipmentClient,
            preferences: MemoryPreferences(filter: filter),
            now: { pollTime },
            sleep: { _ in }
        )
        return (store, shipmentClient)
    }

    // MARK: the isolation guarantee

    /// The load-bearing test of this feature. A failed version lookup must cost
    /// the version and nothing else: the open list refreshed fine, so reporting
    /// it as stale would be a lie about the part that worked.
    ///
    /// If this fails, someone has moved the shipment lookups inside `refresh()`'s
    /// existing do/catch.
    @Test("a failed releases lookup leaves the open list and lastError untouched")
    func releasesFailureIsIsolated() async {
        let (store, _) = makeStore(
            open: [.success([openPR("a")])],
            merged: [mergedPR("m1")],
            shipmentClient: SpyShipmentClient(releasesFail: true)
        )

        await store.refresh()

        #expect(store.prs.map(\.id) == ["a"])
        #expect(store.lastError == nil)
        #expect(store.lastSuccessfulFetch == pollTime)
        #expect(store.lastShipmentFailure == "releases lookup refused")
    }

    /// Yesterday's answer beats no answer: a blip must not read as "nothing
    /// shipped today".
    @Test("shipments survive a refresh that fails outright")
    func shipmentsSurviveFailure() async {
        let client = SpyShipmentClient(
            releases: ["R_1": [release("v1.226.0")]],
            answers: [ContainmentKey(pullRequestID: "m1", tagName: "v1.226.0"): true]
        )
        let (store, _) = makeStore(
            open: [.success([]), .failure(.notJSON)],
            merged: [mergedPR("m1")],
            shipmentClient: client
        )

        await store.refresh()
        #expect(store.shipments.count == 1)
        #expect(store.shipments.first?.status == .released(
            version: "v1.226.0",
            url: release("v1.226.0").url
        ))

        await store.refresh()
        #expect(store.lastError != nil)
        #expect(store.shipments.count == 1, "a failed refresh must not empty the section")
    }

    // MARK: not asking twice

    /// A shipment resolved to a version is settled. Re-comparing it on every
    /// poll would spend a request a minute for a day to be told the same thing.
    @Test("a resolved shipment is not compared again on the next poll")
    func resolvedShipmentIsNotReasked() async {
        let client = SpyShipmentClient(
            releases: ["R_1": [release("v1.226.0")]],
            answers: [ContainmentKey(pullRequestID: "m1", tagName: "v1.226.0"): true]
        )
        let (store, spy) = makeStore(
            open: [.success([]), .success([])],
            merged: [mergedPR("m1")],
            shipmentClient: client
        )

        await store.refresh()
        await store.refresh()

        let spied = try! #require(spy)
        #expect(spied.containmentAsks.count == 2, "both polls reach the client")
        #expect(spied.containmentAsks[0].count == 1, "the first poll asks")
        #expect(spied.containmentAsks[1].isEmpty, "the second poll has nothing left to ask")
        #expect(store.shipments.first?.status == .released(
            version: "v1.226.0",
            url: release("v1.226.0").url
        ))
    }

    // MARK: the filter applies after the merge too

    @Test("a merged pull request in a hidden organization never becomes a shipment")
    func hiddenOrganizationIsExcluded() async {
        let (store, _) = makeStore(
            merged: [mergedPR("m1", repo: "hidden-org/thing")],
            filter: PRFilter(hiddenOrganizations: ["hidden-org"])
        )

        await store.refresh()
        #expect(store.shipments.isEmpty)
    }

    @Test("a merged pull request from a private repository is excluded when those are hidden")
    func privateRepositoryIsExcluded() async {
        let (store, _) = makeStore(
            merged: [mergedPR("m1", isPrivate: true)],
            filter: PRFilter(showsPrivateRepositories: false)
        )

        await store.refresh()
        #expect(store.shipments.isEmpty)
    }

    // MARK: the window

    @Test("a merge older than the retention window is dropped")
    func oldMergeIsDropped() async {
        let (store, _) = makeStore(
            merged: [
                mergedPR("fresh"),
                mergedPR("old", mergedAt: pollTime.addingTimeInterval(-48 * 3600)),
            ]
        )

        await store.refresh()
        #expect(store.shipments.map(\.id) == ["fresh"])
    }

    // MARK: no live client

    /// Under a debug override there is nobody to ask about releases. The rows
    /// still say whether CI passed; they simply never carry a version.
    @Test("without a shipment client the rows still resolve from their own checks")
    func noClientStillResolves() async {
        let (store, _) = makeStore(merged: [mergedPR("m1")], shipmentClient: nil)

        await store.refresh()
        #expect(store.shipments.count == 1)
        #expect(store.shipments.first?.status == .pending)
        #expect(store.lastShipmentFailure == nil)
    }
}

private struct SilentNotifier: ReadyPRNotifying {
    func notifyReady(_ pr: PullRequest) async throws {}
}

private struct EmptyIDStore: NotifiedIDStore {
    func load() -> Set<String> { [] }
    func save(_ ids: Set<String>) {}
}
