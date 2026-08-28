import Foundation
import Testing
@testable import PRMasterCore

private func makeClient(_ outcomes: [StubOutcome]) -> (client: GitHubClient, stub: StubSession) {
    let stub = StubSession(outcomes: outcomes)
    let provider = TokenProvider(
        paths: ["/fake/gh"],
        fileExists: { _ in true },
        run: { _ in TokenProvider.RunResult(stdout: "gho_faketokenvalue", exitCode: 0) }
    )
    return (GitHubClient(tokenProvider: provider, session: stub.session), stub)
}

private let approvedOK = Data("""
{"data":{"addPullRequestReview":{"pullRequestReview":{"state":"APPROVED"}}}}
""".utf8)

/// GitHub accepted the mutation and recorded a review that is not an approval.
/// The reason the decoder trusts `state` rather than the absence of errors.
private let pending = Data("""
{"data":{"addPullRequestReview":{"pullRequestReview":{"state":"PENDING"}}}}
""".utf8)

private let commented = Data("""
{"data":{"addPullRequestReview":{"pullRequestReview":{"state":"COMMENTED"}}}}
""".utf8)

private let dismissed = Data("""
{"data":{"addPullRequestReview":{"pullRequestReview":{"state":"DISMISSED"}}}}
""".utf8)

/// A state added to GitHub's schema after this app was built. The safest reading
/// of "I do not know what this is" is that the approval was not confirmed.
private let unfamiliarState = Data("""
{"data":{"addPullRequestReview":{"pullRequestReview":{"state":"SUPERSEDED"}}}}
""".utf8)

private let nullPayload = Data("""
{"data":{"addPullRequestReview":null}}
""".utf8)

/// What GitHub says when you try to approve your own pull request. The search
/// excludes those, so seeing this means the snapshot was wrong — and the user
/// needs the real sentence, not a paraphrase.
private let ownPullRequest = Data("""
{"data":null,"errors":[{"message":"Can not approve your own pull request"}]}
""".utf8)

private let teamsOK = Data("""
{"data":{"viewer":{"organizations":{"nodes":[
  {"login":"Lansweeper",
   "member":{"nodes":[{"name":"Asset Cortex","combinedSlug":"Lansweeper/asset-cortex"}]},
   "admin":{"nodes":[]}}
]}}}}
""".utf8)

private let searchOK = Data("""
{"data":{"s0":{"issueCount":3,"nodes":[
  {"id":"PR_1","number":909,"title":"fix it",
   "url":"https://github.com/Lansweeper/x/pull/909",
   "headRefOid":"a408f981","createdAt":"2026-08-26T08:50:26Z",
   "updatedAt":"2026-08-26T09:10:06Z","reviewDecision":"REVIEW_REQUIRED",
   "author":{"login":"someone"},
   "repository":{"nameWithOwner":"Lansweeper/x","isPrivate":false},
   "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}
]}}}
""".utf8)

private let team = Team(
    combinedSlug: "Lansweeper/asset-cortex", organization: "Lansweeper", name: "Asset Cortex"
)

@Suite("Approval and team fetching")
struct ApprovalTests {

    // MARK: - The approve request

    @Test("sends an approval carrying the pull request id and the commit")
    func requestShape() async throws {
        let ctx = makeClient([.response(status: 200, body: approvedOK)])
        try await ctx.client.approve(id: "PR_node123", commitOID: "deadbeef")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("addPullRequestReview"))
        #expect(body.contains("APPROVE"))
        #expect(body.contains("PR_node123"))
        #expect(body.contains("deadbeef"))
        // Selected so the decoder has something to insist on.
        #expect(body.contains("state"))
    }

    /// The one thing about this mutation worth stating twice: `commitOID` is not
    /// the control `expectedHeadOid` is on the merge. GitHub pins the review to
    /// the commit rather than refusing one that has moved since, so this records
    /// what was approved — it does not stop an approval of a stale snapshot.
    /// `ApproveCoordinator` is the whole of that protection.
    @Test("no expectedHeadOid is sent, because this mutation has none")
    func pinsRatherThanGuards() async throws {
        let ctx = makeClient([.response(status: 200, body: approvedOK)])
        try await ctx.client.approve(id: "PR_1", commitOID: "deadbeef")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("expectedHeadOid") == false)
        #expect(body.contains("commitOID"))
    }

    /// A review body would be posted publicly under the user's name. Approving
    /// from a menu bar is a gesture, not a comment, so there is nothing to say.
    @Test("no review body is sent")
    func noBody() async throws {
        let ctx = makeClient([.response(status: 200, body: approvedOK)])
        try await ctx.client.approve(id: "PR_1", commitOID: "deadbeef")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("REQUEST_CHANGES") == false)
        #expect(body.contains("\"body\"") == false)
    }

    // MARK: - The approve answer

    @Test("a confirmed approval does not throw")
    func successIsSilent() async throws {
        let ctx = makeClient([.response(status: 200, body: approvedOK)])
        try await ctx.client.approve(id: "PR_1", commitOID: "deadbeef")
    }

    /// GitHub's own wording, for the same reason the merge and the close keep it.
    /// "Can not approve your own pull request" tells the user exactly what
    /// happened; a paraphrase would not.
    @Test("a refusal surfaces GitHub's wording verbatim")
    func refusalIsVerbatim() async throws {
        let ctx = makeClient([.response(status: 200, body: ownPullRequest)])
        await #expect(throws: PRMasterError.approveRejected("Can not approve your own pull request")) {
            try await ctx.client.approve(id: "PR_1", commitOID: "deadbeef")
        }
    }

    /// Treating this as success would drop the row from the list while nothing
    /// had been approved — the user would believe they had reviewed it.
    @Test("a null payload is a refusal, not a success")
    func nullPayloadThrows() async throws {
        let ctx = makeClient([.response(status: 200, body: nullPayload)])
        await #expect(throws: PRMasterError.self) {
            try await ctx.client.approve(id: "PR_1", commitOID: "deadbeef")
        }
    }

    /// Every one of these arrives as a well-formed 200 with no errors array. Only
    /// `APPROVED` is evidence that an approval happened.
    @Test("anything but a confirmed approval is a failure", arguments: [
        ("PENDING", pending),
        ("COMMENTED", commented),
        ("DISMISSED", dismissed),
        ("an unfamiliar state", unfamiliarState),
    ])
    func unconfirmedStateThrows(state: String, body: Data) async throws {
        let ctx = makeClient([.response(status: 200, body: body)])
        await #expect(throws: PRMasterError.self, "state \(state) must not read as approved") {
            try await ctx.client.approve(id: "PR_1", commitOID: "deadbeef")
        }
    }

    @Test("a non-JSON body is reported as such")
    func htmlBodyThrows() async throws {
        let ctx = makeClient([.response(status: 200, body: Data("<html>nope</html>".utf8))])
        await #expect(throws: PRMasterError.notJSON) {
            try await ctx.client.approve(id: "PR_1", commitOID: "deadbeef")
        }
    }

    // MARK: - Fetching teams

    @Test("fetching teams sends the discovery query and decodes it")
    func fetchesTeams() async throws {
        let ctx = makeClient([.response(status: 200, body: teamsOK)])
        let teams = try await ctx.client.fetchTeams()

        #expect(teams.map(\.combinedSlug) == ["Lansweeper/asset-cortex"])
        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("role: MEMBER"))
        #expect(body.contains("role: ADMIN"))
    }

    // MARK: - Fetching review requests

    @Test("fetching review requests sends one search per team")
    func fetchesRequests() async throws {
        let ctx = makeClient([.response(status: 200, body: searchOK)])
        let snapshot = try await ctx.client.fetchReviewRequests(
            teams: [team], filter: TeamFilter(), window: .twoWeeks
        )

        #expect(snapshot.requests.map(\.id) == ["PR_1"])
        #expect(snapshot.pendingCounts["Lansweeper/asset-cortex"] == 3)

        // Read back through JSON rather than as raw text: JSONSerialization
        // escapes the slash in a slug as `\/`, so a substring check on the body
        // would be asserting the encoder's habits rather than the query.
        let sent = try #require(ctx.stub.requests.first?.body)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        )
        let variables = try #require(payload["variables"] as? [String: Any])
        let search = try #require(variables["q0"] as? String)

        #expect(search.hasPrefix(
            "is:pr is:open archived:false draft:false "
                + "team-review-requested:Lansweeper/asset-cortex -author:@me -reviewed-by:@me"
        ))
        // The cutoff is stamped by the client at call time, so only its shape is
        // assertable here — ReviewWindowTests pins the value.
        #expect(search.contains("created:>"))
        #expect(search.hasSuffix("sort:updated-desc"))
        #expect(variables["n0"] as? Int == 20)
    }

    /// The guard belongs in the adapter as well as in the store: a request about
    /// no teams is a rate-limit point spent on nothing, the same rule
    /// `fetchReleases` follows for an empty repository list.
    @Test("no teams sends no request at all")
    func noTeamsSkipsTheRequest() async throws {
        let ctx = makeClient([])
        let snapshot = try await ctx.client.fetchReviewRequests(
            teams: [], filter: TeamFilter(), window: .twoWeeks
        )

        #expect(snapshot == .empty)
        #expect(ctx.stub.requests.isEmpty)
    }

    @Test("the window being off sends no request at all")
    func offSkipsTheRequest() async throws {
        let ctx = makeClient([])
        let snapshot = try await ctx.client.fetchReviewRequests(
            teams: [team], filter: TeamFilter(), window: .off
        )

        #expect(snapshot == .empty)
        #expect(ctx.stub.requests.isEmpty)
    }
}
