import Foundation
import Testing
@testable import PRMasterCore

/// Records every close that reached the client, so "did not close" can be
/// asserted rather than assumed.
private final class SpyCloser: PullRequestClosing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private let error: PRMasterError?

    init(error: PRMasterError? = nil) { self.error = error }

    var calls: [String] { lock.withLock { _calls } }

    func closePullRequest(id: String) async throws {
        lock.withLock { _calls.append(id) }
        if let error { throw error }
    }
}

@MainActor
@Suite("CloseCoordinator")
struct CloseCoordinatorTests {

    @Test("confirming closes and forwards the id unchanged")
    func confirmCloses() async {
        let closer = SpyCloser()
        let outcome = await CloseCoordinator(client: closer, closingAllowed: true)
            .attempt(id: "PR_node1") { true }

        #expect(outcome == .closed)
        #expect(closer.calls == ["PR_node1"])
    }

    /// The whole point of the gate: declining must reach no network at all.
    @Test("cancelling never calls the client")
    func cancelDoesNotClose() async {
        let closer = SpyCloser()
        let outcome = await CloseCoordinator(client: closer, closingAllowed: true)
            .attempt(id: "PR_node1") { false }

        #expect(outcome == .cancelled)
        #expect(closer.calls.isEmpty, "a declined close must not reach GitHub")
    }

    /// Sharper here than it is for the merge. Fixtures are captured from live
    /// responses, so a fixture row carries a real node ID — and `closePullRequest`
    /// takes no `expectedHeadOid`, so nothing downstream would refuse it. This
    /// gate is the only thing standing between a demo row and a closed pull
    /// request somebody was still working on.
    @Test("a debug override refuses without closing")
    func debugOverrideRefuses() async {
        let closer = SpyCloser()
        let outcome = await CloseCoordinator(client: closer, closingAllowed: false)
            .attempt(id: "PR_real") { true }

        #expect(outcome == .refusedDebugOverride)
        #expect(closer.calls.isEmpty, "debug data must never reach a real close")
    }

    @Test("a debug override refuses before even asking the user")
    func debugOverrideDoesNotPrompt() async {
        let asked = Asked()
        _ = await CloseCoordinator(client: SpyCloser(), closingAllowed: false)
            .attempt(id: "PR_real") {
                asked.record()
                return true
            }
        #expect(asked.count == 0, "no dialog for an action that will be refused")
    }

    @Test("a rejected close surfaces GitHub's wording verbatim")
    func failureIsVerbatim() async {
        let message = "Resource not accessible by integration"
        let closer = SpyCloser(error: .closeRejected(message))
        let outcome = await CloseCoordinator(client: closer, closingAllowed: true)
            .attempt(id: "PR_1") { true }

        #expect(outcome == .failed(message))
    }

    /// A close GitHub accepted without confirming. The coordinator must not
    /// launder that into a success, or the row would look closed and come back.
    @Test("an unconfirmed close is reported as a failure")
    func unconfirmedIsFailure() async {
        let closer = SpyCloser(
            error: .closeRejected("GitHub did not confirm the pull request was closed.")
        )
        let outcome = await CloseCoordinator(client: closer, closingAllowed: true)
            .attempt(id: "PR_1") { true }

        #expect(outcome == .failed("GitHub did not confirm the pull request was closed."))
    }

    @Test("a transport failure still reports a usable message")
    func networkFailure() async {
        let closer = SpyCloser(error: .network(URLError(.notConnectedToInternet)))
        let outcome = await CloseCoordinator(client: closer, closingAllowed: true)
            .attempt(id: "PR_1") { true }

        #expect(outcome == .failed("No internet connection."))
    }

    /// An error that is not a `PRMasterError` at all still has to produce a
    /// sentence, not an empty alert.
    @Test("an unexpected error still reports something")
    func unexpectedError() async {
        struct Odd: Error, LocalizedError {
            var errorDescription: String? { "something odd happened" }
        }
        // Its own stub, because SpyCloser only carries a PRMasterError.
        let outcome = await CloseCoordinator(client: ThrowingCloser(Odd()), closingAllowed: true)
            .attempt(id: "PR_1") { true }

        #expect(outcome == .failed("something odd happened"))
    }
}

private struct ThrowingCloser: PullRequestClosing {
    let error: Error
    init(_ error: Error) { self.error = error }
    func closePullRequest(id: String) async throws { throw error }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func record() { lock.withLock { _count += 1 } }
}
