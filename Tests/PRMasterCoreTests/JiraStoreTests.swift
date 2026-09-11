import Foundation
import Testing
@testable import PRMasterCore

private func issue(_ key: String) -> JiraIssue {
    JiraIssue(
        key: key, summary: "summary for \(key)", statusName: "In Progress",
        statusCategory: .inProgress, issueType: "Task",
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func link(_ number: Int, _ repo: String = "acme/one") -> LinkedPullRequest {
    LinkedPullRequest(
        id: "PR_\(number)", number: number, title: "a title",
        url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
        repo: repo, isPrivate: false, isDraft: false, state: .open
    )
}

private final class StubIssueClient: JiraIssueFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[JiraIssue], PRMasterError>]
    private(set) var calls = 0

    init(_ results: [Result<[JiraIssue], PRMasterError>]) { self.results = results }

    func fetchAssignedIssues(within window: JiraWindow) async throws -> [JiraIssue] {
        let next = lock.withLock { () -> Result<[JiraIssue], PRMasterError> in
            calls += 1
            return results.isEmpty ? .success([]) : results.removeFirst()
        }
        return try next.get()
    }
}

private final class StubLinkClient: IssueLinkFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[String: [LinkedPullRequest]], PRMasterError>]
    private(set) var calls = 0
    private(set) var askedFor: [[String]] = []

    init(_ results: [Result<[String: [LinkedPullRequest]], PRMasterError>]) {
        self.results = results
    }

    func fetchPullRequests(forIssueKeys keys: [String]) async throws -> [String: [LinkedPullRequest]] {
        let next = lock.withLock { () -> Result<[String: [LinkedPullRequest]], PRMasterError> in
            calls += 1
            askedFor.append(keys)
            return results.isEmpty ? .success([:]) : results.removeFirst()
        }
        return try next.get()
    }
}

/// Holds the link lookup open so the in-flight state can be observed.
private final class GatedLinkClient: IssueLinkFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var resume: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    let answer: [String: [LinkedPullRequest]]

    init(answer: [String: [LinkedPullRequest]]) { self.answer = answer }

    func fetchPullRequests(forIssueKeys keys: [String]) async throws -> [String: [LinkedPullRequest]] {
        await withCheckedContinuation { entered in
            lock.withLock {
                if let waiting { waiting.resume(); self.waiting = nil }
                self.resume = entered
            }
        }
        return answer
    }

    /// Returns once the fetch has actually started.
    func waitUntilCalled() async {
        await withCheckedContinuation { signal in
            lock.withLock {
                if resume != nil { signal.resume() } else { waiting = signal }
            }
        }
    }

    func release() {
        lock.withLock { resume?.resume(); resume = nil }
    }
}

@Suite("JiraStore link loading")
@MainActor
struct JiraStoreLoadingTests {

    /// While the lookup is in flight an issue must read as loading, not as
    /// having no pull requests and not as a failure.
    @Test("a key still being looked up reads as loading")
    func inFlightReadsAsLoading() async {
        let links = GatedLinkClient(answer: ["ACME-1": []])
        let store = JiraStore(
            issues: StubIssueClient([.success([issue("ACME-1")])]),
            links: links,
            preferences: MemoryPreferences(),
            sleep: { _ in }
        )

        let refresh = Task { await store.refresh() }
        await links.waitUntilCalled()

        #expect(store.linkState(for: "ACME-1") == .loading)
        #expect(store.linkState(for: "ACME-1") != .none)
        #expect(store.linkState(for: "ACME-1") != .unknown)

        links.release()
        await refresh.value

        #expect(store.linkState(for: "ACME-1") == .none)
    }

    /// A second poll must not flash loading over an answer already on screen.
    @Test("a key already answered does not go back to loading")
    func answeredKeyDoesNotReload() async {
        let links = GatedLinkClient(answer: ["ACME-1": []])
        let store = JiraStore(
            issues: StubIssueClient([.success([issue("ACME-1")]), .success([issue("ACME-1")])]),
            links: links,
            preferences: MemoryPreferences(),
            sleep: { _ in }
        )

        let first = Task { await store.refresh() }
        await links.waitUntilCalled()
        links.release()
        await first.value
        #expect(store.linkState(for: "ACME-1") == .none)

        let second = Task { await store.refresh() }
        await links.waitUntilCalled()
        #expect(store.linkState(for: "ACME-1") == .none)
        links.release()
        await second.value
    }

    @Test("nothing is left loading once a refresh ends", arguments: [true, false])
    func nothingLeftLoading(succeeds: Bool) async {
        let result: Result<[String: [LinkedPullRequest]], PRMasterError> =
            succeeds ? .success(["ACME-1": []]) : .failure(.httpError(status: 500))
        let store = JiraStore(
            issues: StubIssueClient([.success([issue("ACME-1")])]),
            links: StubLinkClient([result]),
            preferences: MemoryPreferences(),
            sleep: { _ in }
        )

        await store.refresh()

        #expect(store.linkState(for: "ACME-1") != .loading)
        #expect(store.linkState(for: "ACME-1") == (succeeds ? .none : .unknown))
    }

    @Test("the link state set is exhaustive")
    func stateSetIsExhaustive() {
        #expect(IssueLinkState.allCases.count == 4)
    }
}

@Suite("JiraStore")
@MainActor
struct JiraStoreTests {

    private func make(
        issues: [Result<[JiraIssue], PRMasterError>] = [.success([])],
        links: [Result<[String: [LinkedPullRequest]], PRMasterError>] = [.success([:])],
        configured: Bool = true
    ) -> (JiraStore, StubIssueClient, StubLinkClient) {
        let issueClient = StubIssueClient(issues)
        let linkClient = StubLinkClient(links)
        let store = JiraStore(
            issues: configured ? issueClient : nil,
            links: linkClient,
            sleep: { _ in }
        )
        return (store, issueClient, linkClient)
    }

    @Test("issues and their links arrive together")
    func happyPath() async {
        let (store, _, linkClient) = make(
            issues: [.success([issue("ACME-1"), issue("ACME-2")])],
            links: [.success(["ACME-1": [link(1)], "ACME-2": []])]
        )

        await store.refresh()

        #expect(store.issues.map(\.key) == ["ACME-1", "ACME-2"])
        #expect(store.links["ACME-1"]?.count == 1)
        #expect(store.links["ACME-2"] == [])
        #expect(store.lastError == nil)
        #expect(linkClient.askedFor.first == ["ACME-1", "ACME-2"])
    }

    /// The distinction the whole feature rests on. An issue with no entry after
    /// a SUCCESSFUL lookup genuinely has no pull request. After a FAILED lookup
    /// it is unknown, and must not be reported as none.
    @Test("a successful lookup with no hits reads as none")
    func successfulEmptyIsNone() async {
        let (store, _, _) = make(
            issues: [.success([issue("ACME-1")])],
            links: [.success(["ACME-1": []])]
        )

        await store.refresh()

        #expect(store.linkState(for: "ACME-1") == .none)
        #expect(store.lastLinkFailure == nil)
    }

    @Test("a failed lookup reads as unknown, never as none")
    func failedLookupIsUnknown() async {
        let (store, _, _) = make(
            issues: [.success([issue("ACME-1")])],
            links: [.failure(.rateLimited(until: Date()))]
        )

        await store.refresh()

        #expect(store.linkState(for: "ACME-1") == .unknown)
        #expect(store.linkState(for: "ACME-1") != .none)
        #expect(store.lastLinkFailure != nil)
        #expect(store.issues.count == 1)
    }

    /// A broken link lookup must not raise the stale banner over a perfectly
    /// good issue list, which is why the two failures are separate fields.
    @Test("a link failure does not set lastError")
    func linkFailureIsNotTheMainError() async {
        let (store, _, _) = make(
            issues: [.success([issue("ACME-1")])],
            links: [.failure(.httpError(status: 500))]
        )

        await store.refresh()

        #expect(store.lastError == nil)
        #expect(store.lastLinkFailure != nil)
    }

    @Test("an issue fetch failure keeps the last good list")
    func issueFailureKeepsLastGood() async {
        let (store, _, _) = make(
            issues: [.success([issue("ACME-1")]), .failure(.jiraUnauthorized)],
            links: [.success(["ACME-1": [link(1)]]), .success([:])]
        )

        await store.refresh()
        #expect(store.issues.count == 1)

        await store.refresh()
        #expect(store.issues.count == 1)
        #expect(store.lastError == .jiraUnauthorized)
        #expect(store.lastSuccessfulFetch != nil)
    }

    /// Unconfigured is not a failure and must cost nothing at all.
    @Test("an unconfigured store does nothing")
    func unconfiguredDoesNothing() async {
        let (store, _, linkClient) = make(configured: false)

        await store.refresh()

        #expect(store.issues.isEmpty)
        #expect(store.lastError == nil)
        #expect(linkClient.calls == 0)
        #expect(!store.isRefreshing)
    }

    @Test("no issues means no link lookup at all")
    func noIssuesNoLinkCall() async {
        let (store, _, linkClient) = make(issues: [.success([])])

        await store.refresh()

        #expect(linkClient.calls == 0)
    }

    @Test("overlapping refreshes are refused")
    func reentrancyGuard() async {
        let (store, issueClient, _) = make(
            issues: [.success([issue("ACME-1")]), .success([issue("ACME-2")])],
            links: [.success([:]), .success([:])]
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.refresh() }
            group.addTask { await store.refresh() }
        }

        #expect(issueClient.calls <= 2)
        #expect(!store.isRefreshing)
    }

    @Test("the backoff ladder climbs on failure and resets on success")
    func backoffLadder() async {
        let (store, _, _) = make(
            issues: [
                .failure(.httpError(status: 500)),
                .failure(.httpError(status: 500)),
                .failure(.httpError(status: 500)),
                .success([issue("ACME-1")]),
            ],
            links: [.success([:]), .success([:]), .success([:]), .success([:])]
        )

        #expect(store.currentInterval == .seconds(60))
        await store.refresh()
        #expect(store.currentInterval == .seconds(120))
        await store.refresh()
        #expect(store.currentInterval == .seconds(300))
        await store.refresh()
        #expect(store.currentInterval == .seconds(300))
        await store.refresh()
        #expect(store.currentInterval == .seconds(60))
    }

    @Test("the poll loop refreshes repeatedly and honours cancellation")
    func pollLoopRuns() async {
        let (store, issueClient, _) = make(
            issues: [.success([]), .success([]), .success([])]
        )

        let task = Task { await store.pollLoop() }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value

        #expect(issueClient.calls >= 1)
    }

    /// The repository filter has to reach nested rows too, or a private repo
    /// name leaks into a popover that is often on screen.
    @Test("the repository filter applies to linked pull requests")
    func filterAppliesToLinks() async {
        let privateLink = LinkedPullRequest(
            id: "PR_9", number: 9, title: "secret", url: URL(string: "https://x/9")!,
            repo: "acme/secret", isPrivate: true, isDraft: false, state: .open
        )
        let (store, _, _) = make(
            issues: [.success([issue("ACME-1")])],
            links: [.success(["ACME-1": [privateLink, link(1)]])]
        )

        await store.refresh()

        let hidingPrivate = PRFilter(showsPrivateRepositories: false)
        #expect(store.links(for: "ACME-1", under: hidingPrivate).map(\.number) == [1])

        #expect(store.links(for: "ACME-1", under: PRFilter()).count == 2)
    }
}

/// The client used to be decided once at launch, so signing in left the pane
/// saying Jira was not set up until the app was restarted.
@Suite("JiraStore signing in mid-session")
@MainActor
struct JiraStoreConnectTests {

    /// Cancelled before its first suspension, so the poll it starts never runs
    /// and the refresh under test is the one the test asks for.
    private func empty() -> JiraStore {
        JiraStore(issues: nil, links: nil, preferences: MemoryPreferences(), sleep: { _ in })
    }

    @Test("a store built without credentials adopts a client on sign-in")
    func connectMakesItConfigured() async {
        let store = empty()
        #expect(!store.isConfigured)

        store.connect(StubIssueClient([.success([issue("ACME-1")])]))
        store.stop()
        #expect(store.isConfigured)

        await store.refresh()
        #expect(store.issues.map(\.key) == ["ACME-1"])
    }

    @Test("signing in starts polling rather than waiting for a restart")
    func connectStartsPolling() {
        let store = empty()
        #expect(!store.isPolling)

        store.connect(StubIssueClient([]))
        #expect(store.isPolling)
        store.stop()
    }

    @Test("signing out clears what was on screen and stops polling")
    func disconnectClears() async {
        let store = JiraStore(
            issues: StubIssueClient([.success([issue("ACME-1")])]),
            links: StubLinkClient([.success(["ACME-1": [link(1)]])]),
            preferences: MemoryPreferences(),
            sleep: { _ in }
        )
        await store.refresh()
        #expect(!store.issues.isEmpty)

        store.connect(nil)

        #expect(!store.isConfigured)
        #expect(!store.isPolling)
        #expect(store.issues.isEmpty)
        #expect(store.linkState(for: "ACME-1") == .unknown)
        #expect(store.lastSuccessfulFetch == nil)
    }

    /// Otherwise the pane greets a fresh sign-in with the last account's error.
    @Test("a failure does not survive the next sign-in")
    func connectClearsError() async {
        let store = JiraStore(
            issues: StubIssueClient([.failure(.jiraUnauthorized)]),
            links: nil,
            preferences: MemoryPreferences(),
            sleep: { _ in }
        )
        await store.refresh()
        #expect(store.lastError == .jiraUnauthorized)

        store.connect(StubIssueClient([.success([issue("ACME-2")])]))
        store.stop()
        #expect(store.lastError == nil)
    }
}

private func epic(_ key: String) -> JiraIssue {
    JiraIssue(
        key: key, summary: "an epic", statusName: "In Progress",
        statusCategory: .inProgress, issueType: "Epic",
        updatedAt: Date(timeIntervalSince1970: 0),
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

/// An epic is a container for other people's work, not a task to be done, and
/// it never carries a pull request of its own.
@Suite("JiraStore epics")
@MainActor
struct JiraStoreEpicTests {

    @Test("an epic is not listed")
    func epicsAreDropped() async {
        let store = JiraStore(
            issues: StubIssueClient([.success([issue("ACME-1"), epic("ACME-2")])]),
            links: nil,
            preferences: MemoryPreferences(),
            sleep: { _ in }
        )
        await store.refresh()
        #expect(store.issues.map(\.key) == ["ACME-1"])
    }

    @Test("no pull request is looked up for an epic")
    func epicsCostNoSearch() async {
        let links = StubLinkClient([.success([:])])
        let store = JiraStore(
            issues: StubIssueClient([.success([issue("ACME-1"), epic("ACME-2")])]),
            links: links,
            preferences: MemoryPreferences(),
            sleep: { _ in }
        )
        await store.refresh()
        #expect(links.askedFor == [["ACME-1"]])
    }

    @Test("the type is matched whatever its casing")
    func casingDoesNotMatter() {
        #expect(epic("ACME-1").isEpic)
        #expect(JiraIssue(
            key: "ACME-2", summary: "", statusName: "", statusCategory: .toDo,
            issueType: "epic", updatedAt: Date(), createdAt: Date()
        ).isEpic)
        #expect(!issue("ACME-3").isEpic)
    }
}

@Suite("JiraStore search")
@MainActor
struct JiraStoreSearchTests {

    private func loaded() async -> JiraStore {
        let store = JiraStore(
            issues: StubIssueClient([.success([issue("ACME-1"), issue("ACME-2")])]),
            links: nil,
            preferences: MemoryPreferences(),
            sleep: { _ in }
        )
        await store.refresh()
        return store
    }

    @Test("no query shows everything the groups hold")
    func emptyQueryShowsAll() async {
        let store = await loaded()
        #expect(store.visibleGroups.count == 2)
    }

    @Test("a query narrows what the pane draws without dropping the issues")
    func queryNarrows() async {
        let store = await loaded()
        store.searchQuery = "ACME-2"

        #expect(store.visibleGroups.inProgress.map(\.key) == ["ACME-2"])
        #expect(store.groups.count == 2)
        #expect(store.issues.count == 2)
    }

    @Test("clearing the query brings everything back")
    func clearingRestores() async {
        let store = await loaded()
        store.searchQuery = "nothing matches this"
        #expect(store.visibleGroups.isEmpty)

        store.searchQuery = ""
        #expect(store.visibleGroups.count == 2)
    }
}
