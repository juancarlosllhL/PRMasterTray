/// The close half of `GitHubClient`, so the gate in front of it can be tested
/// without a network stack.
public protocol PullRequestClosing: Sendable {
    func closePullRequest(id: String) async throws
}

extension GitHubClient: PullRequestClosing {}

public enum CloseOutcome: Equatable, Sendable {
    /// The user declined at the confirmation step.
    case cancelled
    /// Refused before asking: the app is showing data from a debug override, so
    /// its PR identifiers cannot be trusted to name a real pull request.
    case refusedDebugOverride
    case closed
    /// GitHub's own message, verbatim — including its refusal to confirm.
    case failed(String)
}

/// Guards closing a pull request.
///
/// A sibling of `MergeCoordinator` rather than a second method on it. Closing is
/// not irreversible the way a merge is — GitHub can reopen a pull request, though
/// only while its head branch still exists and has not been force-pushed — and
/// folding two different risk classes into one decision table would blur the
/// documentation of both.
///
/// The confirmation is injected for the same reason it is there: the decision
/// table — refuse / cancel / close / fail — stays testable while only the literal
/// `NSAlert` lives in the app target.
public struct CloseCoordinator: Sendable {

    private let client: PullRequestClosing
    private let closingAllowed: Bool

    /// - Parameter closingAllowed: false whenever any debug override is active.
    ///   This carries more weight than the merge's equivalent. There, a real head
    ///   oid at least has to match; here `closePullRequest` accepts no
    ///   `expectedHeadOid` at all, so nothing downstream can refuse a request
    ///   built from a fixture row that happens to name a real pull request. This
    ///   flag is the whole of the protection, which is why — unlike
    ///   `Debug.mergingOffered` — there is no demo exception to it: that one is
    ///   only safe because it swaps in a no-op merger, and there is no no-op
    ///   equivalent here.
    public init(client: PullRequestClosing, closingAllowed: Bool) {
        self.client = client
        self.closingAllowed = closingAllowed
    }

    public func attempt(
        id: String,
        // Main-actor bound: the confirmation is a modal dialog.
        confirm: @MainActor () async -> Bool
    ) async -> CloseOutcome {
        // Checked before confirming: never present a dialog for an action that
        // is going to be refused anyway.
        guard closingAllowed else { return .refusedDebugOverride }
        guard await confirm() else { return .cancelled }

        do {
            try await client.closePullRequest(id: id)
            return .closed
        } catch let error as PRMasterError {
            return .failed(error.errorDescription ?? "The pull request was not closed.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
