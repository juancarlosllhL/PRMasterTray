/// Why a pull request can or cannot be merged right now.
///
/// This is the one decision the whole app exists to make; everything else is
/// plumbing that feeds it or renders its result.
public enum Readiness: Sendable, Equatable, CaseIterable {
    /// Still a draft. Shown dimmed, never notified about.
    case draft
    /// Merge conflicts with the base branch.
    case conflicted
    /// A required check failed or errored.
    case checksFailing
    /// Checks are still running, or GitHub is recomputing mergeability.
    case checksPending
    /// Head is behind base; needs updating before it can merge.
    case behind
    /// Branch protection is withholding the merge, typically pending review.
    case blocked
    /// Mergeable right now.
    case ready

    /// Evaluates a pull request against GitHub's own merge state.
    ///
    /// Order matters: the earlier a condition appears, the more it dominates.
    /// Draft status outranks everything, and check results outrank merge state
    /// so a red PR never reads as merely "blocked".
    public static func evaluate(_ pr: PullRequest) -> Readiness {
        if pr.isDraft { return .draft }
        if pr.mergeable == .conflicting { return .conflicted }

        switch pr.checks {
        case .failure, .error:
            return .checksFailing
        case .pending, .expected:
            return .checksPending
        case .success, nil:
            // nil means the repo has no CI at all. Treating that as pending
            // would leave such PRs permanently unready.
            break
        }

        switch pr.mergeState {
        case .clean, .unstable, .hasHooks:
            return .ready
        case .behind:
            return .behind
        case .unknown:
            // GitHub is still computing mergeability, which happens right
            // after every push. Calling this ready would fire a notification
            // on each one.
            return .checksPending
        case .blocked, .dirty:
            return .blocked
        }
    }
}
