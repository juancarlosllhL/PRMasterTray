import Foundation
import Testing
@testable import PRMasterCore

/// Records every approval that reached the client, so "did not approve" can be
/// asserted rather than assumed.
private final class SpyApprover: PullRequestApproving, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(id: String, oid: String)] = []
    private let error: Error?

    init(error: Error? = nil) { self.error = error }

    var calls: [(id: String, oid: String)] { lock.withLock { _calls } }

    func approve(id: String, commitOID: String) async throws {
        lock.withLock { _calls.append((id, commitOID)) }
        if let error { throw error }
    }
}

@MainActor
@Suite("ApproveCoordinator")
struct ApproveCoordinatorTests {

    @Test("confirming approves and forwards the id and commit unchanged")
    func confirmApproves() async {
        let approver = SpyApprover()
        let outcome = await ApproveCoordinator(client: approver, approvingAllowed: true)
            .attempt(id: "PR_node1", commitOID: "abc123") { true }

        #expect(outcome == .approved)
        #expect(approver.calls.count == 1)
        #expect(approver.calls.first?.id == "PR_node1")
        #expect(approver.calls.first?.oid == "abc123")
    }

    /// The whole point of the gate: declining must reach no network at all.
    @Test("cancelling never calls the client")
    func cancelDoesNotApprove() async {
        let approver = SpyApprover()
        let outcome = await ApproveCoordinator(client: approver, approvingAllowed: true)
            .attempt(id: "PR_1", commitOID: "abc") { false }

        #expect(outcome == .cancelled)
        #expect(approver.calls.isEmpty)
    }

    /// A fixture row carries a real node ID and a real head oid, and `commitOID`
    /// pins the review rather than refusing a stale one — so nothing downstream
    /// would stop this from posting a real approval on a real pull request that
    /// was only ever meant to be a rendering sample.
    @Test("a debug override refuses without calling the client")
    func overrideRefuses() async {
        let approver = SpyApprover()
        let outcome = await ApproveCoordinator(client: approver, approvingAllowed: false)
            .attempt(id: "PR_1", commitOID: "abc") { true }

        #expect(outcome == .refusedDebugOverride)
        #expect(approver.calls.isEmpty)
    }

    /// Checked before confirming, so the user is never shown a dialog for
    /// something that was going to be refused regardless — the rule
    /// `MergeCoordinator` and `CloseCoordinator` both follow.
    @Test("a refusal never presents the confirmation")
    func overrideDoesNotAsk() async {
        var asked = false
        let outcome = await ApproveCoordinator(client: SpyApprover(), approvingAllowed: false)
            .attempt(id: "PR_1", commitOID: "abc") {
                asked = true
                return true
            }

        #expect(outcome == .refusedDebugOverride)
        #expect(asked == false)
    }

    /// GitHub's own wording, which is worth keeping here more than anywhere: this
    /// is the message that says the snapshot was wrong rather than the app.
    @Test("a rejection carries GitHub's message verbatim")
    func failureIsVerbatim() async {
        let approver = SpyApprover(
            error: PRMasterError.approveRejected("Can not approve your own pull request")
        )
        let outcome = await ApproveCoordinator(client: approver, approvingAllowed: true)
            .attempt(id: "PR_1", commitOID: "abc") { true }

        #expect(outcome == .failed("Can not approve your own pull request"))
    }

    /// An error that is not a `PRMasterError` still has to produce a sentence
    /// rather than falling through as a success.
    @Test("an unexpected error still fails, with something sayable")
    func nonDomainErrorFails() async {
        struct Boom: Error {}
        let outcome = await ApproveCoordinator(
            client: SpyApprover(error: Boom()), approvingAllowed: true
        ).attempt(id: "PR_1", commitOID: "abc") { true }

        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.isEmpty == false)
    }

    /// The four outcomes are distinct, so the caller cannot conflate a refusal
    /// with a cancellation and quietly show nothing.
    @Test("the four outcomes are distinguishable")
    func outcomesAreDistinct() {
        let all: [ApproveOutcome] = [
            .cancelled, .refusedDebugOverride, .approved, .failed("x"),
        ]
        #expect(Set(all.map(String.init(describing:))).count == 4)
    }
}
