public enum ApproveOutcome: Equatable, Sendable {
    /// The user declined at the confirmation step.
    case cancelled
    /// Refused before asking: the app is showing data from a debug override, so
    /// its PR identifiers cannot be trusted to name a real pull request.
    case refusedDebugOverride
    case approved
    /// GitHub's own message, verbatim — including its refusal to confirm.
    case failed(String)
}

/// Guards posting an approval under the user's name.
///
/// The third sibling of `MergeCoordinator` and `CloseCoordinator` rather than a
/// method on either. Approving is not irreversible the way a merge is — a review
/// can be dismissed — but it is the only write in this app aimed at somebody
/// else's pull request, and colleagues merge on the strength of it. Folding three
/// different risk classes into one decision table would blur all three.
///
/// The confirmation is injected on the same terms as the other two: the decision
/// table — refuse / cancel / approve / fail — stays testable while only the
/// literal `NSAlert` lives in the app target.
public struct ApproveCoordinator: Sendable {

    private let client: PullRequestApproving
    private let approvingAllowed: Bool

    /// - Parameter approvingAllowed: false whenever any debug override is active,
    ///   with **no** demo exception. This follows `CloseCoordinator`'s rule rather
    ///   than `MergeCoordinator`'s, and for a closely related reason.
    ///
    ///   Fixtures are routinely captured from live API responses, so a fixture row
    ///   carries a real node ID and a real head oid. On the merge, `expectedHeadOid`
    ///   is at least a real control that GitHub enforces. Here `commitOID` is not:
    ///   GitHub pins the review to the named commit rather than refusing one that
    ///   moved, so an approval built from a fixture row would simply succeed
    ///   against the real pull request it names.
    ///
    ///   `MergeCoordinator`'s demo exception is safe only because it swaps in a
    ///   no-op merger. There is no no-op approver, and inventing one would mean a
    ///   code path whose whole job is to look like it approved something.
    public init(client: PullRequestApproving, approvingAllowed: Bool) {
        self.client = client
        self.approvingAllowed = approvingAllowed
    }

    public func attempt(
        id: String,
        commitOID: String,
        body: String? = nil,
        // Main-actor bound: the confirmation is a modal dialog, and it is handed
        // the body so it can show the remark that is actually about to be posted.
        confirm: @MainActor (String?) async -> Bool
    ) async -> ApproveOutcome {
        // Checked before confirming: never present a dialog for an action that
        // is going to be refused anyway.
        guard approvingAllowed else { return .refusedDebugOverride }
        guard await confirm(body) else { return .cancelled }

        do {
            try await client.approve(id: id, commitOID: commitOID, body: body)
            return .approved
        } catch let error as PRMasterError {
            return .failed(error.errorDescription ?? "The approval was not recorded.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
