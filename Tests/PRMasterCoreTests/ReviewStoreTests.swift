import Foundation
import Testing
@testable import PRMasterCore

private func team(_ slug: String) -> Team {
    Team(combinedSlug: "Lansweeper/\(slug)", organization: "Lansweeper", name: slug.capitalized)
}

private let cortex = team("asset-cortex")
private let cloud = team("cloud-2")

/// A fixed instant the store's clock is pinned to, so ages are meaningful.
private let now = Date(timeIntervalSince1970: 1_786_692_165)

private func request(
    _ id: String,
    repo: String = "Lansweeper/LECAIChatAssistant",
    isPrivate: Bool = false,
    createdAt: Date = now.addingTimeInterval(-86_400),
    updatedAt: Date = now.addingTimeInterval(-3_600),
    title: String = "t",
    additions: Int = 40,
    deletions: Int = 10,
    changedFiles: Int = 3,
    teams: [Team] = [cortex]
) -> ReviewRequest {
    ReviewRequest(
        id: id,
        number: 1,
        title: title,
        url: URL(string: "https://github.com/\(repo)/pull/1")!,
        repo: repo,
        isPrivate: isPrivate,
        author: "someone",
        headRefOid: "oid-\(id)",
        checks: .success,
        reviewDecision: .reviewRequired,
        createdAt: createdAt,
        updatedAt: updatedAt,
        additions: additions,
        deletions: deletions,
        changedFiles: changedFiles,
        teams: teams
    )
}

/// Answers a scripted sequence for each of the two reads, so discovery and search
/// can be made to fail independently.
private final class StubReviewClient: ReviewRequestFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var teamResults: [Result<[Team], PRMasterError>]
    private var searchResults: [Result<ReviewSnapshot, PRMasterError>]
    private var _searchCalls: [(teams: [Team], filter: TeamFilter, window: ReviewWindow)] = []
    private var _teamCalls = 0

    init(
        teams: [Result<[Team], PRMasterError>] = [],
        searches: [Result<ReviewSnapshot, PRMasterError>] = []
    ) {
        self.teamResults = teams
        self.searchResults = searches
    }

    var searchCalls: [(teams: [Team], filter: TeamFilter, window: ReviewWindow)] {
        lock.withLock { _searchCalls }
    }
    var teamCalls: Int { lock.withLock { _teamCalls } }

    func fetchTeams() async throws -> [Team] {
        let result = lock.withLock { () -> Result<[Team], PRMasterError>? in
            _teamCalls += 1
            return teamResults.isEmpty ? nil : teamResults.removeFirst()
        }
        guard let result else { return [] }
        return try result.get()
    }

    func fetchReviewRequests(
        teams: [Team], filter: TeamFilter, window: ReviewWindow
    ) async throws -> ReviewSnapshot {
        let result = lock.withLock { () -> Result<ReviewSnapshot, PRMasterError>? in
            _searchCalls.append((teams, filter, window))
            return searchResults.isEmpty ? nil : searchResults.removeFirst()
        }
        guard let result else { return .empty }
        return try result.get()
    }
}

private final class SpyApprover: PullRequestApproving, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(id: String, oid: String, body: String?)] = []
    private let error: Error?

    init(error: Error? = nil) { self.error = error }

    var calls: [(id: String, oid: String, body: String?)] { lock.withLock { _calls } }

    func approve(id: String, commitOID: String, body: String?) async throws {
        lock.withLock { _calls.append((id, commitOID, body)) }
        if let error { throw error }
    }
}

@MainActor
@Suite("ReviewStore")
struct ReviewStoreTests {

    private func makeStore(
        client: StubReviewClient? = nil,
        approver: ApproveCoordinator? = nil,
        preferences: MemoryPreferences = MemoryPreferences(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> ReviewStore {
        ReviewStore(
            client: client,
            approver: approver,
            preferences: preferences,
            now: { now },
            sleep: sleep
        )
    }

    // MARK: - A successful refresh

    @Test("a successful refresh populates the rows, the teams and the counts")
    func successPopulates() async {
        let client = StubReviewClient(
            teams: [.success([cortex, cloud])],
            searches: [.success(ReviewSnapshot(
                requests: [request("PR_1")],
                pendingCounts: ["Lansweeper/asset-cortex": 8, "Lansweeper/cloud-2": 852]
            ))]
        )
        let store = makeStore(client: client)
        await store.refresh()

        #expect(store.requests.map(\.id) == ["PR_1"])
        #expect(store.teams == [cortex, cloud])
        #expect(store.pendingCount(for: cortex) == 8)
        #expect(store.pendingCount(for: cloud) == 852)
        #expect(store.lastError == nil)
        #expect(store.lastSuccessfulFetch == now)
    }

    @Test("the discovered teams are persisted for the next launch")
    func persistsTeams() async {
        let preferences = MemoryPreferences()
        let client = StubReviewClient(teams: [.success([cortex])], searches: [.success(.empty)])
        await makeStore(client: client, preferences: preferences).refresh()

        #expect(preferences.knownTeams() == [cortex])
    }

    @Test("the search is told which teams, which filter and which window")
    func passesSettingsToTheSearch() async {
        let preferences = MemoryPreferences(
            reviewWindow: .oneMonth,
            teamFilter: TeamFilter(disabledTeams: ["Lansweeper/cloud-2"])
        )
        let client = StubReviewClient(
            teams: [.success([cortex, cloud])], searches: [.success(.empty)]
        )
        await makeStore(client: client, preferences: preferences).refresh()

        let call = client.searchCalls.first
        #expect(call?.teams == [cortex, cloud])
        #expect(call?.filter.disabledTeams == ["Lansweeper/cloud-2"])
        #expect(call?.window == .oneMonth)
    }

    // MARK: - Failure

    /// The rule `PRStore` follows for its own list: a wifi blip must not read as
    /// nothing waiting on any of your teams.
    @Test("a failed search keeps the last good rows")
    func staleBeatsBlank() async {
        let client = StubReviewClient(
            teams: [.success([cortex]), .success([cortex])],
            searches: [
                .success(ReviewSnapshot(requests: [request("PR_1")], pendingCounts: [:])),
                .failure(.network(URLError(.timedOut))),
            ]
        )
        let store = makeStore(client: client)
        await store.refresh()
        await store.refresh()

        #expect(store.requests.map(\.id) == ["PR_1"])
        #expect(store.lastError == .network(URLError(.timedOut)))
    }

    /// Teams change rarely, so yesterday's list beats no list. Without this a
    /// discovery blip would empty the section even though the rows are fetchable.
    @Test("a failed discovery falls back to the persisted teams and still lists rows")
    func discoveryFallsBackToPersisted() async {
        let preferences = MemoryPreferences(knownTeams: [cortex])
        let client = StubReviewClient(
            teams: [.failure(.unauthorized)],
            searches: [.success(ReviewSnapshot(
                requests: [request("PR_1")], pendingCounts: ["Lansweeper/asset-cortex": 3]
            ))]
        )
        let store = makeStore(client: client, preferences: preferences)
        await store.refresh()

        #expect(store.teams == [cortex])
        #expect(store.requests.map(\.id) == ["PR_1"])
        #expect(client.searchCalls.first?.teams == [cortex])
        // Reported even though the rows arrived, or a missing read:org scope
        // would be invisible for as long as the cached list held out.
        #expect(store.lastError == .unauthorized)
    }

    /// Nothing to fall back on. Searching would send a request about no teams and
    /// come back empty, which would read as "nothing is waiting on you".
    @Test("a failed discovery with no cached teams reports and searches nothing")
    func discoveryFailureWithNoCache() async {
        let client = StubReviewClient(teams: [.failure(.unauthorized)])
        let store = makeStore(client: client)
        await store.refresh()

        #expect(store.lastError == .unauthorized)
        #expect(client.searchCalls.isEmpty)
        #expect(store.lastSuccessfulFetch == nil)
    }

    /// Being in no teams is a real answer rather than a failure.
    @Test("belonging to no teams is not an error")
    func noTeamsIsNotAnError() async {
        let client = StubReviewClient(teams: [.success([])], searches: [.success(.empty)])
        let store = makeStore(client: client)
        await store.refresh()

        #expect(store.teams.isEmpty)
        #expect(store.requests.isEmpty)
        #expect(store.lastError == nil)
    }

    // MARK: - Off

    @Test("switching the window off empties the section on the spot")
    func offEmptiesImmediately() async {
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(
                requests: [request("PR_1")], pendingCounts: ["Lansweeper/asset-cortex": 3]
            ))]
        )
        let store = makeStore(client: client)
        await store.refresh()
        #expect(store.requests.isEmpty == false)

        store.window = .off

        // Emptied without waiting for a round trip: waiting to clear a section
        // the user has just switched off reads as the switch not working.
        #expect(store.requests.isEmpty)
        #expect(store.pendingCounts.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test("a refresh while off sends no request at all")
    func offSendsNothing() async {
        let preferences = MemoryPreferences(reviewWindow: .off)
        let client = StubReviewClient(teams: [.success([cortex])])
        let store = makeStore(client: client, preferences: preferences)
        await store.refresh()

        #expect(client.teamCalls == 0)
        #expect(client.searchCalls.isEmpty)
    }

    @Test("the window and the team filter persist on assignment")
    func settingsPersist() async {
        let preferences = MemoryPreferences()
        let store = makeStore(client: StubReviewClient(), preferences: preferences)

        store.window = .oneWeek
        store.teamFilter = TeamFilter(disabledTeams: ["Lansweeper/cloud-2"])

        #expect(preferences.reviewWindow() == .oneWeek)
        #expect(preferences.teamFilter().disabledTeams == ["Lansweeper/cloud-2"])
    }

    // MARK: - No live client

    /// Under a debug override there is nothing to ask, and a fixture's team
    /// slugs are not worth asking about.
    @Test("no client means no rows and no error")
    func noClient() async {
        let store = makeStore(client: nil)
        await store.refresh()

        #expect(store.requests.isEmpty)
        #expect(store.lastError == nil)
    }

    // MARK: - The repository filter

    /// The switch that hides private repositories has to reach this section, or
    /// it silently stops meaning what it says — these are other people's pull
    /// requests, in a popover often on screen beside somebody else.
    @Test("the repository filter is applied on the way out")
    func repositoryFilterApplies() async {
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(
                requests: [
                    request("PR_public", repo: "Lansweeper/a", isPrivate: false),
                    request("PR_private", repo: "Lansweeper/b", isPrivate: true),
                    request("PR_other", repo: "acme/c", isPrivate: false),
                ],
                pendingCounts: [:]
            ))]
        )
        let store = makeStore(client: client)
        await store.refresh()

        #expect(store.visible(under: PRFilter()).count == 3)
        #expect(
            store.visible(under: PRFilter(showsPrivateRepositories: false)).map(\.id)
                == ["PR_public", "PR_other"]
        )
        #expect(
            store.visible(under: PRFilter(hiddenOrganizations: ["acme"])).map(\.id)
                == ["PR_public", "PR_private"]
        )
    }

    /// A row can age past the window between polls. The section is derived rather
    /// than snapshotted so it goes quiet by itself instead of showing something
    /// the next search would not return.
    @Test("a row older than the window is not shown even before the next poll")
    func agedOutRowIsHidden() async {
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(
                requests: [
                    request("PR_fresh", createdAt: now.addingTimeInterval(-86_400)),
                    request("PR_ancient", createdAt: now.addingTimeInterval(-40 * 86_400)),
                ],
                pendingCounts: [:]
            ))]
        )
        let store = makeStore(client: client)
        await store.refresh()

        #expect(store.visible(under: PRFilter()).map(\.id) == ["PR_fresh"])
    }

    /// The dismissal search is not per team, so a row it returns can be
    /// attributed to a team the user switched off. Derived rather than left to
    /// the refetch, so switching a team off empties its rows on the spot.
    @Test("a row whose every team is switched off is not shown")
    func disabledTeamRowIsHidden() async {
        let preferences = MemoryPreferences(
            teamFilter: TeamFilter(disabledTeams: ["Lansweeper/cloud-2"])
        )
        let client = StubReviewClient(
            teams: [.success([cortex, cloud])],
            searches: [.success(ReviewSnapshot(
                requests: [
                    request("PR_cortex", teams: [cortex]),
                    request("PR_cloud", teams: [cloud]),
                    request("PR_both", teams: [cortex, cloud]),
                ],
                pendingCounts: [:]
            ))]
        )
        let store = makeStore(client: client, preferences: preferences)
        await store.refresh()

        #expect(store.visible(under: PRFilter()).map(\.id) == ["PR_cortex", "PR_both"])
    }

    // MARK: - Truncation

    /// A capped list that says nothing about being capped is the silent failure
    /// this section could most easily commit.
    @Test("a team with more pending than rows in hand reads as truncated")
    func truncationIsVisible() async {
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(
                requests: [request("PR_1")],
                pendingCounts: ["Lansweeper/asset-cortex": 40]
            ))]
        )
        let store = makeStore(client: client)
        await store.refresh()

        #expect(store.isTruncated(under: PRFilter()))
    }

    @Test("everything in hand does not read as truncated")
    func noTruncation() async {
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(
                requests: [request("PR_1")],
                pendingCounts: ["Lansweeper/asset-cortex": 1]
            ))]
        )
        let store = makeStore(client: client)
        await store.refresh()

        #expect(store.isTruncated(under: PRFilter()) == false)
    }

    /// A disabled team's count is real but its rows were never fetched, so it
    /// must not make the visible section look truncated.
    @Test("a switched-off team does not make the section read as truncated")
    func disabledTeamDoesNotTruncate() async {
        let preferences = MemoryPreferences(
            teamFilter: TeamFilter(disabledTeams: ["Lansweeper/cloud-2"])
        )
        let client = StubReviewClient(
            teams: [.success([cortex, cloud])],
            searches: [.success(ReviewSnapshot(
                requests: [request("PR_1")],
                pendingCounts: ["Lansweeper/asset-cortex": 1, "Lansweeper/cloud-2": 852]
            ))]
        )
        let store = makeStore(client: client, preferences: preferences)
        await store.refresh()

        #expect(store.isTruncated(under: PRFilter()) == false)
        // The count is still offered, which is what the settings row needs.
        #expect(store.pendingCount(for: cloud) == 852)
    }

    // MARK: - Approving

    @Test("a confirmed approval drops the row without waiting for a poll")
    func approvalRemovesTheRow() async {
        let approver = SpyApprover()
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(
                requests: [request("PR_1"), request("PR_2")], pendingCounts: [:]
            ))]
        )
        let store = makeStore(
            client: client,
            approver: ApproveCoordinator(client: approver, approvingAllowed: true)
        )
        await store.refresh()

        let outcome = await store.approve(store.requests[0]) { _ in true }

        #expect(outcome == .approved)
        #expect(store.requests.map(\.id) == ["PR_2"])
        #expect(approver.calls.first?.id == "PR_1")
        // The commit the user was looking at, not whatever is current.
        #expect(approver.calls.first?.oid == "oid-PR_1")
        #expect(store.approvingIDs.isEmpty)
    }

    @Test("a failed approval keeps the row and says what happened")
    func failedApprovalKeepsTheRow() async {
        let approver = SpyApprover(
            error: PRMasterError.approveRejected("Can not approve your own pull request")
        )
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(requests: [request("PR_1")], pendingCounts: [:]))]
        )
        let store = makeStore(
            client: client,
            approver: ApproveCoordinator(client: approver, approvingAllowed: true)
        )
        await store.refresh()

        let outcome = await store.approve(store.requests[0]) { _ in true }

        #expect(outcome == .failed("Can not approve your own pull request"))
        #expect(store.requests.map(\.id) == ["PR_1"])
        #expect(store.approvingIDs.isEmpty)
    }

    @Test("cancelling keeps the row and clears the indicator")
    func cancelledApproval() async {
        let approver = SpyApprover()
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(requests: [request("PR_1")], pendingCounts: [:]))]
        )
        let store = makeStore(
            client: client,
            approver: ApproveCoordinator(client: approver, approvingAllowed: true)
        )
        await store.refresh()

        #expect(await store.approve(store.requests[0]) { _ in false } == .cancelled)
        #expect(store.requests.map(\.id) == ["PR_1"])
        #expect(approver.calls.isEmpty)
        #expect(store.approvingIDs.isEmpty)
    }

    /// No coordinator at all is the debug-override case, and it must refuse
    /// rather than silently doing nothing.
    @Test("no approver refuses instead of quietly succeeding")
    func noApproverRefuses() async {
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(requests: [request("PR_1")], pendingCounts: [:]))]
        )
        let store = makeStore(client: client, approver: nil)
        await store.refresh()

        #expect(await store.approve(store.requests[0]) { _ in true } == .refusedDebugOverride)
        #expect(store.requests.map(\.id) == ["PR_1"])
    }

    // MARK: - The approval remark

    @Test("an approval carries a remark from the row's own bucket")
    func approvalCarriesAQuip() async {
        let approver = SpyApprover()
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(
                requests: [request("PR_1", title: ":memo: document the read:org scope")],
                pendingCounts: [:]
            ))]
        )
        let store = makeStore(
            client: client,
            approver: ApproveCoordinator(client: approver, approvingAllowed: true)
        )
        await store.refresh()

        var shown: String?
        _ = await store.approve(store.requests[0]) { body in
            shown = body
            return true
        }

        let posted = approver.calls.first?.body
        #expect(ApprovalQuip.lines(for: .documentation).contains(posted ?? ""))
        // The dialog must show the line that is actually posted, not another draw.
        #expect(shown == posted)
    }

    @Test("switching the remark off approves with no body at all")
    func quipsCanBeSwitchedOff() async {
        let preferences = MemoryPreferences()
        preferences.setApprovalQuipsEnabled(false)
        let approver = SpyApprover()
        let client = StubReviewClient(
            teams: [.success([cortex])],
            searches: [.success(ReviewSnapshot(requests: [request("PR_1")], pendingCounts: [:]))]
        )
        let store = makeStore(
            client: client,
            approver: ApproveCoordinator(client: approver, approvingAllowed: true),
            preferences: preferences
        )
        await store.refresh()

        _ = await store.approve(store.requests[0]) { _ in true }

        #expect(store.approvalQuipsEnabled == false)
        #expect(approver.calls.first?.body == nil)
    }

    @Test("the switch persists")
    func quipSettingPersists() async {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences: preferences)

        #expect(store.approvalQuipsEnabled)
        store.approvalQuipsEnabled = false

        #expect(preferences.approvalQuipsEnabled() == false)
    }

    // MARK: - Reentrancy and polling

    /// `@MainActor` methods are reentrant across `await`, so without a guard the
    /// slower of two overlapping refreshes wins and can restore stale data — the
    /// bug `PRStore.refresh` documents.
    @Test("two overlapping refreshes do not both fetch")
    func reentrancyGuard() async {
        let client = StubReviewClient(
            teams: [.success([cortex]), .success([cortex])],
            searches: [.success(.empty), .success(.empty)]
        )
        let store = makeStore(client: client)

        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)

        #expect(client.teamCalls == 1)
    }

    @Test("the poll loop refreshes repeatedly and honours cancellation")
    func pollLoop() async {
        let client = StubReviewClient(
            teams: (0..<3).map { _ in .success([cortex]) },
            searches: (0..<3).map { _ in .success(.empty) }
        )
        let store = makeStore(client: client, sleep: { _ in
            try await Task.sleep(for: .milliseconds(1))
        })

        let task = Task { await store.pollLoop() }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await task.value

        #expect(client.teamCalls >= 2)
    }

    @Test("the loop waits longer after failures")
    func backoffGrows() async {
        let store = makeStore(client: StubReviewClient())
        #expect(store.currentInterval == .seconds(60))

        let failing = StubReviewClient(teams: [.failure(.unauthorized)])
        let failedStore = makeStore(client: failing)
        await failedStore.refresh()

        #expect(failedStore.currentInterval > .seconds(60))
    }
}
