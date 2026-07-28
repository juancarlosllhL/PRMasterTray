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

private let mergedOK = Data("""
{"data":{"mergePullRequest":{"pullRequest":{"merged":true}}}}
""".utf8)

/// GitHub's real wording when the head has moved since the snapshot.
private let headMoved = Data("""
{"data":{"mergePullRequest":null},"errors":[
  {"message":"Head branch was modified. Review and try the merge again."}
]}
""".utf8)

@Suite
struct MergeTests {

    @Test("sends a squash merge carrying the id and expected head oid")
    func requestShape() async throws {
        let ctx = makeClient([.response(status: 200, body: mergedOK)])
        try await ctx.client.squashMerge(id: "PR_node123", expectedHeadOid: "abc123def")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("mergePullRequest"))
        #expect(body.contains("SQUASH"))
        #expect(body.contains("PR_node123"))
        #expect(body.contains("abc123def"))
        // The guard must live in the mutation itself, not merely be passed along.
        #expect(body.contains("expectedHeadOid"))
    }

    /// Without this the app could merge commits the user never saw in the list.
    @Test("never sends a merge without the head oid guard")
    func guardIsMandatory() async throws {
        let ctx = makeClient([.response(status: 200, body: mergedOK)])
        try await ctx.client.squashMerge(id: "PR_node123", expectedHeadOid: "abc123def")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("expectedHeadOid"))
        #expect(!body.contains("\"oid\":\"\""))
    }

    @Test("a merged response does not throw")
    func successIsSilent() async throws {
        let ctx = makeClient([.response(status: 200, body: mergedOK)])
        try await ctx.client.squashMerge(id: "PR_1", expectedHeadOid: "oid")
    }

    /// The user needs GitHub's own wording; a paraphrase would hide why it failed.
    @Test("a rejected merge surfaces GitHub's message verbatim")
    func rejectionIsVerbatim() async throws {
        let ctx = makeClient([.response(status: 200, body: headMoved)])
        do {
            try await ctx.client.squashMerge(id: "PR_1", expectedHeadOid: "stale")
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .mergeRejected(let message) = error else {
                Issue.record("expected .mergeRejected, got \(error)")
                return
            }
            #expect(message == "Head branch was modified. Review and try the merge again.")
            #expect(error.errorDescription == message)
        }
    }

    /// A null or unmerged payload must not read as success, or the app would
    /// drop the PR from the list while it is still open on GitHub.
    @Test("a response that did not merge is treated as a failure")
    func unmergedIsFailure() async throws {
        let ctx = makeClient([.response(
            status: 200,
            body: Data(#"{"data":{"mergePullRequest":{"pullRequest":{"merged":false}}}}"#.utf8)
        )])
        await #expect(throws: PRMasterError.self) {
            try await ctx.client.squashMerge(id: "PR_1", expectedHeadOid: "oid")
        }
    }

    @Test("transport failures still map to network")
    func networkFailure() async throws {
        let ctx = makeClient([.failure(URLError(.timedOut))])
        await #expect(throws: PRMasterError.self) {
            try await ctx.client.squashMerge(id: "PR_1", expectedHeadOid: "oid")
        }
    }
}
