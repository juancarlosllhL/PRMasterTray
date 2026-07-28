/// The merge half of `GitHubClient`, so the gate in front of it can be tested
/// without a network stack.
public protocol PullRequestMerging: Sendable {
    func squashMerge(id: String, expectedHeadOid: String) async throws
}

extension GitHubClient: PullRequestMerging {}

public enum MergeOutcome: Equatable, Sendable {
    /// The user declined at the confirmation step.
    case cancelled
    /// Refused before asking: the app is showing data from a debug override,
    /// so its PR identifiers cannot be trusted to name a real pull request.
    case refusedDebugOverride
    case merged
    /// GitHub's own message, verbatim.
    case failed(String)
}

/// Guards the one irreversible operation in the app.
///
/// The confirmation is injected rather than built here, so the decision table —
/// refuse / cancel / merge / fail — is testable while only the literal `NSAlert`
/// stays in the app target.
public struct MergeCoordinator: Sendable {

    private let client: PullRequestMerging
    private let mergingAllowed: Bool

    /// - Parameter mergingAllowed: false whenever any debug override is active.
    ///   Fixtures are routinely captured from live API responses, so a fixture
    ///   row can carry a real node ID and a real head oid. Merging from one
    ///   would merge a real pull request that was only meant to be a rendering
    ///   sample, and `expectedHeadOid` would not stop it — the oid is real too.
    public init(client: PullRequestMerging, mergingAllowed: Bool) {
        self.client = client
        self.mergingAllowed = mergingAllowed
    }

    public func attempt(
        id: String,
        expectedHeadOid: String,
        // Main-actor bound: the confirmation is a modal dialog.
        confirm: @MainActor () async -> Bool
    ) async -> MergeOutcome {
        // Checked before confirming: never present a dialog for an action that
        // is going to be refused anyway.
        guard mergingAllowed else { return .refusedDebugOverride }
        guard await confirm() else { return .cancelled }

        do {
            try await client.squashMerge(id: id, expectedHeadOid: expectedHeadOid)
            return .merged
        } catch let error as PRMasterError {
            return .failed(error.errorDescription ?? "The merge failed.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
