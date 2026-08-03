import Foundation

/// A pull request authored by the signed-in user.
///
/// Raw values match the GitHub GraphQL enums exactly; story 003 layers
/// `Decodable` on top with tolerance for values GitHub adds later.
public struct PullRequest: Identifiable, Sendable, Equatable {
    /// GraphQL node ID. Doubles as the merge target and the notification
    /// dedup key, so it must survive round trips untouched.
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    /// `owner/name`, e.g. `acme/widget-service`.
    public let repo: String
    /// Whether the repository is private. Fetched only so `PRFilter` can hide
    /// these rows: the app is a menu bar item that is often on screen while
    /// somebody else is looking at it.
    public let isPrivate: Bool
    public let isDraft: Bool
    /// Head commit at the time of the snapshot. Passed to the merge mutation
    /// so GitHub refuses to merge commits the user never saw.
    public let headRefOid: String
    public let mergeable: Mergeable
    public let mergeState: MergeStateStatus
    /// `nil` when the repo requires no review at all.
    public let reviewDecision: ReviewDecision?
    /// `nil` when the repo has no CI. Distinct from "checks running".
    public let checks: CheckState?
    public let approvals: Int
    public let updatedAt: Date
    /// When the pull request was opened.
    ///
    /// What the staleness marker measures from, deliberately not `updatedAt`:
    /// `PRStore.updateBehindBranches` pushes a merge commit into behind branches
    /// off the poll loop, which bumps `updatedAt`. Against a base branch that
    /// keeps moving, the app would go on resetting its own staleness signal
    /// forever and nothing would ever be marked. This field only ever moves once.
    public let createdAt: Date

    public var readiness: Readiness { Readiness.evaluate(self) }

    /// The owner half of `repo` — an organization, or the user's own account for
    /// a personal repository. Neither half may contain a slash, so the split is
    /// unambiguous, and GitHub guarantees the field is always `owner/name`.
    public var organization: String {
        String(repo.prefix { $0 != "/" })
    }

    public init(
        id: String,
        number: Int,
        title: String,
        url: URL,
        repo: String,
        isPrivate: Bool,
        isDraft: Bool,
        headRefOid: String,
        mergeable: Mergeable,
        mergeState: MergeStateStatus,
        reviewDecision: ReviewDecision?,
        checks: CheckState?,
        approvals: Int,
        updatedAt: Date,
        createdAt: Date
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repo = repo
        self.isPrivate = isPrivate
        self.isDraft = isDraft
        self.headRefOid = headRefOid
        self.mergeable = mergeable
        self.mergeState = mergeState
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.approvals = approvals
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}

/// GitHub `MergeableState`.
public enum Mergeable: String, Sendable, CaseIterable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"
}

/// GitHub `MergeStateStatus` — the authority on whether a PR can be merged.
///
/// `reviewDecision` is not sufficient: a PR can report `reviewDecision: null`
/// and `mergeable: MERGEABLE` while still being `BLOCKED` by branch protection.
public enum MergeStateStatus: String, Sendable, CaseIterable {
    /// Mergeable and passing.
    case clean = "CLEAN"
    /// Mergeable, but a non-required check is failing.
    case unstable = "UNSTABLE"
    /// Mergeable, with pre-receive hooks to run.
    case hasHooks = "HAS_HOOKS"
    /// Head is behind base and the branch requires being up to date.
    case behind = "BEHIND"
    /// Blocked by branch protection.
    case blocked = "BLOCKED"
    /// Merge conflicts.
    case dirty = "DIRTY"
    /// GitHub is still computing mergeability — transient, seen after a push.
    case unknown = "UNKNOWN"
}

/// GitHub `PullRequestReviewDecision`.
public enum ReviewDecision: String, Sendable, CaseIterable {
    case changesRequested = "CHANGES_REQUESTED"
    case approved = "APPROVED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// GitHub `StatusState`, the rolled-up state of a commit's checks.
public enum CheckState: String, Sendable, CaseIterable {
    /// Declared but not yet reported.
    case expected = "EXPECTED"
    case error = "ERROR"
    case failure = "FAILURE"
    case pending = "PENDING"
    case success = "SUCCESS"
}
