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

private let updatedOK = Data("""
{"data":{"updatePullRequestBranch":{"pullRequest":{"id":"PR_node123","headRefOid":"new456"}}}}
""".utf8)

/// GitHub's wording when the branch moved after the snapshot was taken.
private let headMoved = Data("""
{"data":{"updatePullRequestBranch":null},"errors":[
  {"message":"The head ref did not match the expected head ref."}
]}
""".utf8)

@Suite("Branch update")
struct BranchUpdateTests {

    @Test("sends the update mutation carrying the id and expected head oid")
    func requestShape() async throws {
        let ctx = makeClient([.response(status: 200, body: updatedOK)])
        try await ctx.client.updateBranch(id: "PR_node123", expectedHeadOid: "abc123def")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("updatePullRequestBranch"))
        #expect(body.contains("PR_node123"))
        #expect(body.contains("abc123def"))
        #expect(body.contains("expectedHeadOid"))
    }

    /// REBASE force-pushes the user's branch and would break any local clone.
    /// The default, MERGE, is what GitHub's own "Update branch" button does.
    @Test("never asks for a rebase")
    func neverRebases() async throws {
        let ctx = makeClient([.response(status: 200, body: updatedOK)])
        try await ctx.client.updateBranch(id: "PR_1", expectedHeadOid: "oid")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(!body.contains("REBASE"))
    }

    /// Without the guard the app would merge base into a branch that has moved
    /// on since the snapshot the decision was made from.
    @Test("never sends an update without the head oid guard")
    func guardIsMandatory() async throws {
        let ctx = makeClient([.response(status: 200, body: updatedOK)])
        try await ctx.client.updateBranch(id: "PR_1", expectedHeadOid: "abc")

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("expectedHeadOid"))
        #expect(!body.contains("\"oid\":\"\""))
    }

    @Test("a successful update does not throw")
    func successIsSilent() async throws {
        let ctx = makeClient([.response(status: 200, body: updatedOK)])
        try await ctx.client.updateBranch(id: "PR_1", expectedHeadOid: "oid")
    }

    @Test("a rejected update surfaces GitHub's message verbatim")
    func rejectionIsVerbatim() async throws {
        let ctx = makeClient([.response(status: 200, body: headMoved)])
        do {
            try await ctx.client.updateBranch(id: "PR_1", expectedHeadOid: "stale")
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .updateRejected(let message) = error else {
                Issue.record("expected .updateRejected, got \(error)")
                return
            }
            #expect(message == "The head ref did not match the expected head ref.")
            #expect(error.errorDescription == message)
        }
    }

    /// A null payload means GitHub declined without saying so. Treating it as
    /// success would record the attempt and leave the PR behind forever.
    @Test("a null payload is a failure, not a silent success")
    func nullPayloadIsFailure() async throws {
        let ctx = makeClient([.response(
            status: 200,
            body: Data(#"{"data":{"updatePullRequestBranch":null}}"#.utf8)
        )])
        await #expect(throws: PRMasterError.self) {
            try await ctx.client.updateBranch(id: "PR_1", expectedHeadOid: "oid")
        }
    }

    @Test("transport failures still map to network")
    func networkFailure() async throws {
        let ctx = makeClient([.failure(URLError(.timedOut))])
        await #expect(throws: PRMasterError.self) {
            try await ctx.client.updateBranch(id: "PR_1", expectedHeadOid: "oid")
        }
    }
}
