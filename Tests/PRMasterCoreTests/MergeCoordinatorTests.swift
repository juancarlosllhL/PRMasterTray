import Foundation
import Testing
@testable import PRMasterCore

/// Records every merge that reached the client, so "did not merge" can be
/// asserted rather than assumed.
private final class SpyMerger: PullRequestMerging, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(id: String, oid: String)] = []
    private let error: PRMasterError?

    init(error: PRMasterError? = nil) { self.error = error }

    var calls: [(id: String, oid: String)] { lock.withLock { _calls } }

    func squashMerge(id: String, expectedHeadOid: String) async throws {
        lock.withLock { _calls.append((id, expectedHeadOid)) }
        if let error { throw error }
    }
}

@MainActor
@Suite("MergeCoordinator")
struct MergeCoordinatorTests {

    @Test("confirming merges and forwards the id and oid unchanged")
    func confirmMerges() async {
        let merger = SpyMerger()
        let outcome = await MergeCoordinator(client: merger, mergingAllowed: true)
            .attempt(id: "PR_node1", expectedHeadOid: "abc123") { true }

        #expect(outcome == .merged)
        #expect(merger.calls.count == 1)
        #expect(merger.calls.first?.id == "PR_node1")
        #expect(merger.calls.first?.oid == "abc123")
    }

    /// The whole point of the gate: declining must reach no network at all.
    @Test("cancelling never calls the client")
    func cancelDoesNotMerge() async {
        let merger = SpyMerger()
        let outcome = await MergeCoordinator(client: merger, mergingAllowed: true)
            .attempt(id: "PR_node1", expectedHeadOid: "abc123") { false }

        #expect(outcome == .cancelled)
        #expect(merger.calls.isEmpty, "a declined merge must not reach GitHub")
    }

    /// Fixtures are captured from live responses, so a fixture row can carry a
    /// real node ID. Merging from one would merge a real PR.
    @Test("a debug override refuses without merging")
    func debugOverrideRefuses() async {
        let merger = SpyMerger()
        let outcome = await MergeCoordinator(client: merger, mergingAllowed: false)
            .attempt(id: "PR_real", expectedHeadOid: "realoid") { true }

        #expect(outcome == .refusedDebugOverride)
        #expect(merger.calls.isEmpty, "debug data must never reach a real merge")
    }

    @Test("a debug override refuses before even asking the user")
    func debugOverrideDoesNotPrompt() async {
        let asked = Asked()
        _ = await MergeCoordinator(client: SpyMerger(), mergingAllowed: false)
            .attempt(id: "PR_real", expectedHeadOid: "oid") {
                asked.record()
                return true
            }
        #expect(asked.count == 0, "no dialog for an action that will be refused")
    }

    @Test("a rejected merge surfaces GitHub's wording verbatim")
    func failureIsVerbatim() async {
        let message = "Head branch was modified. Review and try the merge again."
        let merger = SpyMerger(error: .mergeRejected(message))
        let outcome = await MergeCoordinator(client: merger, mergingAllowed: true)
            .attempt(id: "PR_1", expectedHeadOid: "stale") { true }

        #expect(outcome == .failed(message))
    }

    @Test("a transport failure still reports a usable message")
    func networkFailure() async {
        let merger = SpyMerger(error: .network(URLError(.notConnectedToInternet)))
        let outcome = await MergeCoordinator(client: merger, mergingAllowed: true)
            .attempt(id: "PR_1", expectedHeadOid: "oid") { true }

        #expect(outcome == .failed("No internet connection."))
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func record() { lock.withLock { _count += 1 } }
}
