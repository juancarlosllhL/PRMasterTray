import Foundation

/// An open pull request that a team the user belongs to has been asked to review.
///
/// A separate type from `PullRequest` on the same grounds `MergedPullRequest` is
/// one: half of what makes a `PullRequest` is about getting your own change in —
/// `mergeable`, `mergeState`, `approvals`, and the whole of `Readiness` — and
/// none of it is what a reviewer acts on. Modelling that as optionality would
/// push "is this one mine?" into every consumer.
///
/// What it adds instead is the two things a reviewer needs and an author never
/// does: who wrote it, and which of your teams was asked.
public struct ReviewRequest: Identifiable, Sendable, Equatable {

    /// GraphQL node ID. Doubles as the approve target, so it must survive round
    /// trips untouched.
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    /// `owner/name`, e.g. `Lansweeper/LECLuzmoPlugin`.
    public let repo: String
    /// Whether the repository is private. Fetched for exactly the reason
    /// `PullRequest.isPrivate` is, and with more at stake: these are other
    /// people's pull requests, and the switch that hides them has to reach here
    /// too or it silently stops meaning what it says.
    public let isPrivate: Bool
    /// The login of whoever opened it.
    ///
    /// Never the signed-in user. The search excludes them, because GitHub refuses
    /// to let anybody approve their own pull request — and those rows are already
    /// listed in the section above.
    public let author: String
    /// Head commit at the time of the snapshot, passed to the review as
    /// `commitOID` so the approval names the commit the user was looking at.
    ///
    /// Deliberately not called a guard: unlike the merge's `expectedHeadOid`,
    /// GitHub pins the review to this commit rather than refusing one that has
    /// moved since. See `ApproveCoordinator` for what actually protects this.
    public let headRefOid: String
    /// `nil` when the repository has no CI. Distinct from "checks running".
    public let checks: CheckState?
    /// `nil` when the repository requires no review at all. It still reached this
    /// list, so a team was asked regardless.
    public let reviewDecision: ReviewDecision?
    /// When the pull request was opened. What `ReviewWindow` measures from, and
    /// what the row's age is counted from.
    public let createdAt: Date
    public let updatedAt: Date
    /// Fetched for the approval remark only — see `ApprovalQuip`.
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    /// Which of the user's teams were asked — plural, because more than one can
    /// be. Carrying the set is what lets a pull request requested from two of
    /// your teams be one row rather than two.
    public let teams: [Team]
    /// True only for rows the dismissal search found: the per-team searches
    /// cannot see a dismissal, and GitHub's team request is gone by then.
    public let viewerReviewDismissed: Bool

    public var state: ReviewState { ReviewState.evaluate(self) }

    /// The owner half of `repo`, matching `PullRequest.organization` and
    /// `MergedPullRequest.organization` so `PRFilter` treats all three the same.
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
        author: String,
        headRefOid: String,
        checks: CheckState?,
        reviewDecision: ReviewDecision?,
        createdAt: Date,
        updatedAt: Date,
        additions: Int,
        deletions: Int,
        changedFiles: Int,
        teams: [Team],
        viewerReviewDismissed: Bool = false
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repo = repo
        self.isPrivate = isPrivate
        self.author = author
        self.headRefOid = headRefOid
        self.checks = checks
        self.reviewDecision = reviewDecision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.teams = teams
        self.viewerReviewDismissed = viewerReviewDismissed
    }
}

/// The switch that hides private repositories, and the organizations the user
/// chose not to see, both have to reach this section — see `isPrivate`.
extension ReviewRequest: FilterableRepository {}
