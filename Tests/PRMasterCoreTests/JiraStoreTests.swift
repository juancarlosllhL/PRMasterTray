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

    func fetchAssignedIssues() async throws -> [JiraIssue] {
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
