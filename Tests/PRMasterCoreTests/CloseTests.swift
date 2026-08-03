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

private let closedOK = Data("""
{"data":{"closePullRequest":{"pullRequest":{"id":"PR_1","state":"CLOSED"}}}}
""".utf8)

/// GitHub accepted the mutation and left the pull request open. Undocumented, and
/// the reason the decoder trusts `state` rather than the absence of errors.
private let stillOpen = Data("""
{"data":{"closePullRequest":{"pullRequest":{"id":"PR_1","state":"OPEN"}}}}
""".utf8)

private let alreadyMerged = Data("""
{"data":{"closePullRequest":{"pullRequest":{"id":"PR_1","state":"MERGED"}}}}
""".utf8)

/// A state added to GitHub's schema after this app was built. Every other enum in
/// the app degrades to its safest reading; the safest reading of "I do not know
/// what state this is" is that the close was not confirmed.
private let unfamiliarState = Data("""
{"data":{"closePullRequest":{"pullRequest":{"id":"PR_1","state":"ARCHIVED_PENDING_REVIEW"}}}}
""".utf8)

private let nullPayload = Data("""
{"data":{"closePullRequest":null}}
""".utf8)

private let refused = Data("""
{"data":{"closePullRequest":null},"errors":[
  {"message":"Resource not accessible by integration"}
]}
""".utf8)

@Suite
struct CloseTests {

    @Test("sends a close carrying the pull request id")
    func requestShape() async throws {
        let ctx = makeClient([.response(status: 200, body: closedOK)])
        try await ctx.client.closePullRequest(id: "PR_node123")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("closePullRequest"))
        #expect(body.contains("PR_node123"))
        // Selected so the decoder has something to insist on.
        #expect(body.contains("state"))
    }

    /// The inverse of `MergeTests.guardIsMandatory`, and it documents a real
    /// asymmetry rather than an omission: `ClosePullRequestInput` has no
    /// `expectedHeadOid`, so sending one is a schema error, not extra safety.
    /// Nothing downstream can refuse a close aimed at a stale snapshot — which is
    /// why `CloseCoordinator`'s debug gate is the only protection there is.
    @Test("never sends a head oid guard, because GitHub offers none")
    func noHeadOidGuard() async throws {
        let ctx = makeClient([.response(status: 200, body: closedOK)])
        try await ctx.client.closePullRequest(id: "PR_node123")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("expectedHeadOid") == false)
    }

    @Test("a confirmed close does not throw")
    func successIsSilent() async throws {
        let ctx = makeClient([.response(status: 200, body: closedOK)])
        try await ctx.client.closePullRequest(id: "PR_1")
    }

    /// GitHub's own wording, for the same reason the merge keeps it: a paraphrase
    /// would hide which permission or which state was the problem.
    @Test("a refusal surfaces GitHub's wording verbatim")
    func refusalIsVerbatim() async throws {
        let ctx = makeClient([.response(status: 200, body: refused)])
        await #expect(throws: PRMasterError.closeRejected("Resource not accessible by integration")) {
            try await ctx.client.closePullRequest(id: "PR_1")
        }
    }

    /// A refusal GitHub declined to explain. Treating it as success would drop the
    /// row from the list on the next refresh while the pull request stayed open.
    @Test("a null payload is a refusal, not a success")
    func nullPayloadThrows() async throws {
        let ctx = makeClient([.response(status: 200, body: nullPayload)])
        await #expect(throws: PRMasterError.self) {
            try await ctx.client.closePullRequest(id: "PR_1")
        }
    }

    /// GitHub documents no error text for closing something that cannot be closed,
    /// so the state is the only thing worth trusting. Both of these arrive as a
    /// perfectly well-formed 200 with no errors array at all.
    @Test("anything but a confirmed close is a failure", arguments: [
        ("OPEN", stillOpen),
        ("MERGED", alreadyMerged),
        ("an unfamiliar state", unfamiliarState),
    ])
    func unconfirmedStateThrows(state: String, body: Data) async throws {
        let ctx = makeClient([.response(status: 200, body: body)])
        await #expect(throws: PRMasterError.self, "state \(state) must not read as closed") {
            try await ctx.client.closePullRequest(id: "PR_1")
        }
    }

    /// The decoder is the arbiter over JSON only — the same trap the fetch path
    /// hit, where an HTML proxy page produced a screenful of NSCocoaErrorDomain.
    @Test("a non-JSON body is reported as such")
    func htmlBodyThrows() async throws {
        let ctx = makeClient([.response(status: 200, body: Data("<html>nope</html>".utf8))])
        await #expect(throws: PRMasterError.notJSON) {
            try await ctx.client.closePullRequest(id: "PR_1")
        }
    }
}
