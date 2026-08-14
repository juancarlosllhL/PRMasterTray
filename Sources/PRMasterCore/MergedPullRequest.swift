import Foundation

/// A pull request of the user's that has already been merged.
///
/// Deliberately a separate type from `PullRequest` rather than a widening of it.
/// Half of what makes a `PullRequest` — mergeability, review decision, readiness
/// — is meaningless once it is merged, and modelling that as optionality would
/// push the question "is this one merged?" into every consumer.
public struct MergedPullRequest: Identifiable, Sendable, Equatable {
    /// GraphQL node ID, and the key shipments are tracked by across polls.
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    /// `owner/name`, e.g. `acme/widget-service`.
    public let repo: String
    /// The repository's GraphQL node ID, which is what `nodes(ids:)` takes when
    /// the releases for this pull request's repository are looked up. Carried
    /// here so that lookup needs no second round trip to turn a name into a node.
    public let repositoryID: String
    public let isPrivate: Bool
    public let mergedAt: Date
    /// `nil` in the seconds between the merge and GitHub materialising the
    /// commit. An absence, not a failure.
    public let mergeCommitOid: String?
    /// GitHub's rolled-up state over every check on the merge commit, or `nil`
    /// when the repository has no CI at all.
    ///
    /// The authority on whether the pipeline passed, in preference to counting
    /// `contexts`: this covers context types the app does not recognise and
    /// therefore drops, so a failure it cannot name is still a failure it knows
    /// about.
    public let rollupState: CheckState?
    /// The individual checks, normalised from two different wire shapes. Here to
    /// name a failure and to link to the pipeline, not to be tallied.
    public let contexts: [CheckContext]

    /// The owner half of `repo`, matching `PullRequest.organization` so the
    /// filter can treat both the same way.
    public var organization: String {
        String(repo.prefix { $0 != "/" })
    }

    public init(
        id: String,
        number: Int,
        title: String,
        url: URL,
        repo: String,
        repositoryID: String,
        isPrivate: Bool,
        mergedAt: Date,
        mergeCommitOid: String?,
        rollupState: CheckState?,
        contexts: [CheckContext]
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repo = repo
        self.repositoryID = repositoryID
        self.isPrivate = isPrivate
        self.mergedAt = mergedAt
        self.mergeCommitOid = mergeCommitOid
        self.rollupState = rollupState
        self.contexts = contexts
    }
}

/// One check on a merge commit.
///
/// GitHub reports these as a union of `CheckRun` and `StatusContext`, which
/// carry different field names and different state enums for the same idea.
/// Collapsing them at decode time means nothing downstream has to know which
/// shape GitHub happened to use.
public struct CheckContext: Sendable, Equatable {
    /// `CheckRun.name` or `StatusContext.context`, e.g. `CD` or
    /// `ci/circleci: build`.
    public let name: String
    public let state: CheckState
    public let url: URL?
    /// True for a `CheckRun`, whose URL addresses the whole CircleCI workflow.
    /// A `StatusContext` URL addresses a single job within one, which is the
    /// worse place to land — see `WorkflowLink`.
    public let isWorkflow: Bool

    public init(name: String, state: CheckState, url: URL?, isWorkflow: Bool) {
        self.name = name
        self.state = state
        self.url = url
        self.isWorkflow = isWorkflow
    }
}

/// GitHub `CheckStatusState`.
enum CheckRunStatus: String, Sendable, CaseIterable {
    case queued = "QUEUED"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case waiting = "WAITING"
    case pending = "PENDING"
    case requested = "REQUESTED"
}

/// GitHub `CheckConclusionState`.
enum CheckConclusion: String, Sendable, CaseIterable {
    case actionRequired = "ACTION_REQUIRED"
    case cancelled = "CANCELLED"
    case failure = "FAILURE"
    case neutral = "NEUTRAL"
    case success = "SUCCESS"
    case skipped = "SKIPPED"
    case stale = "STALE"
    case startupFailure = "STARTUP_FAILURE"
    case timedOut = "TIMED_OUT"
    /// A value GitHub added after this app was built. Read as "no usable
    /// answer", never as a good one.
    case unknown
}

extension CheckContext {
    /// Collapses a `CheckRun`'s two fields onto the one `StatusContext` uses.
    ///
    /// A run that has not completed is pending whatever its conclusion says.
    /// `cancelled` and `stale` count as failures rather than as still-running:
    /// both are terminal, and a row that goes on claiming "building" for
    /// something that stopped an hour ago is the one answer that is never true.
    static func state(status: CheckRunStatus?, conclusion: CheckConclusion?) -> CheckState {
        guard status == .completed else { return .pending }
        switch conclusion {
        case .success, .neutral, .skipped:
            return .success
        case .failure, .timedOut, .startupFailure, .actionRequired, .cancelled, .stale:
            return .failure
        case .unknown, nil:
            return .pending
        }
    }
}
