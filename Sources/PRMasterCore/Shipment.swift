import Foundation

/// A published GitHub release, which for these repositories is what
/// semantic-release cuts after a merge to the default branch.
public struct Release: Sendable, Equatable {
    public let tagName: String
    public let url: URL
    /// The commit the tag points at. Deliberately *not* how containment is
    /// decided — see `ShipmentResolver`.
    public let tagCommitOid: String
    public let createdAt: Date

    public init(tagName: String, url: URL, tagCommitOid: String, createdAt: Date) {
        self.tagName = tagName
        self.url = url
        self.tagCommitOid = tagCommitOid
        self.createdAt = createdAt
    }
}

/// One promoted version that has to be identified before anything can be said
/// about it.
///
/// Carries both keys because the two sides are keyed differently: promotions by
/// `repo`, because that is what a deployments folder is found from, and releases
/// by `repositoryID`, because that is what the merged search already returns.
public struct ReleaseTagRequest: Sendable, Hashable {
    public let repo: String
    public let repositoryID: String
    public let version: String

    public init(repo: String, repositoryID: String, version: String) {
        self.repo = repo
        self.repositoryID = repositoryID
        self.version = version
    }
}

/// Identifies one containment question: does this release contain the merge
/// commit of this pull request?
public struct ContainmentKey: Hashable, Sendable {
    public let pullRequestID: String
    public let tagName: String

    public init(pullRequestID: String, tagName: String) {
        self.pullRequestID = pullRequestID
        self.tagName = tagName
    }
}

/// One (pull request, release) pair worth asking GitHub about.
public struct ContainmentCandidate: Sendable, Equatable {
    public let pullRequest: MergedPullRequest
    public let release: Release

    public var key: ContainmentKey {
        ContainmentKey(pullRequestID: pullRequest.id, tagName: release.tagName)
    }
}

/// What became of a merged pull request.
public enum ShipStatus: Sendable, Equatable {
    /// Merged, with nothing yet to say about it: the merge commit has not
    /// appeared, or the repository has no CI and cuts no releases.
    case pending
    case building(URL)
    case failed(name: String, url: URL)
    case released(version: String, url: URL)
}

/// Whether a change has reached one environment.
public enum EnvironmentStatus: Sendable, Equatable {
    /// No mapping, no release matching what is promoted there, or no answer yet.
    /// Never a guess in either direction.
    case unknown
    /// That environment is running something that does not contain this change.
    case awaiting(version: String)
    /// This change is in what is promoted there.
    case carrying(version: String)
}

public struct EnvironmentState: Sendable, Equatable {
    public let environment: DeployEnvironment
    public let status: EnvironmentStatus
    /// False while the regions hold different versions, which is what a rollout
    /// mid-flight looks like. The version reported is the lowest of them, so
    /// this is what says "at least this, and further along elsewhere".
    public let regionsAgree: Bool

    public init(
        environment: DeployEnvironment,
        status: EnvironmentStatus,
        regionsAgree: Bool = true
    ) {
        self.environment = environment
        self.status = status
        self.regionsAgree = regionsAgree
    }
}

/// A merged pull request together with what became of it.
public struct Shipment: Identifiable, Sendable, Equatable {
    public let pr: MergedPullRequest
    public let status: ShipStatus
    /// Staging first, and only the environments something is known about.
    public let environments: [EnvironmentState]

    public var id: String { pr.id }

    public init(
        pr: MergedPullRequest,
        status: ShipStatus,
        environments: [EnvironmentState] = []
    ) {
        self.pr = pr
        self.status = status
        self.environments = environments
    }

    /// Where the row goes when it is clicked.
    ///
    /// The pipeline while there is one worth watching, and the release once
    /// there is one: a finished workflow is the least useful page of the three
    /// by the time a version exists, and the version is what the user came for.
    public var destination: URL {
        switch status {
        case .pending:
            return pr.url
        case .building(let url), .failed(_, let url), .released(_, let url):
            return url
        }
    }
}

/// Turns a merged pull request, its checks and its repository's releases into
/// the one thing a row has to say.
///
/// Pure, like `Readiness.evaluate` and `BranchUpdateDecider`: every input is a
/// snapshot and there is no I/O, which is what makes the decision table above
/// testable without a network.
public enum ShipmentResolver {

    /// - Parameters:
    ///   - releases: keyed by `MergedPullRequest.repositoryID`.
    ///   - containment: answers already obtained. A missing entry means "not
    ///     known", which is never treated as "not contained".
    ///   - promotions: every region of every app that ships from a repository,
    ///     keyed by `MergedPullRequest.repo`. Collapsed here, so a repository
    ///     backing several apps is answered across all of them at once.
    public static func resolve(
        merged: [MergedPullRequest],
        releases: [String: [Release]],
        containment: [ContainmentKey: Bool],
        promotions: [String: [PromotedVersion]] = [:]
    ) -> [Shipment] {
        merged.map { pr in
            let repoReleases = releases[pr.repositoryID] ?? []
            return Shipment(
                pr: pr,
                status: status(for: pr, releases: repoReleases, containment: containment),
                environments: environments(
                    for: pr,
                    promotions: EnvironmentPromotion.collapse(promotions[pr.repo] ?? []),
                    releases: repoReleases,
                    containment: containment
                )
            )
        }
    }

    /// Whether each environment is carrying the change.
    ///
    /// Decided by containment, never by comparing version numbers: an
    /// environment can sit on a *higher* version that was cut from another
    /// branch and does not include this merge at all.
    ///
    /// An environment counts as carrying only when every one of its regions
    /// does. A region proven to lack the change settles the environment even if
    /// another has no answer — proof outranks an unknown, but an unknown is
    /// never rounded into a yes.
    static func environments(
        for pr: MergedPullRequest,
        promotions: [EnvironmentPromotion],
        releases: [Release],
        containment: [ContainmentKey: Bool]
    ) -> [EnvironmentState] {
        promotions.map { promotion in
            let answers = promotion.versions.map {
                carries(pr: pr, version: $0, releases: releases, containment: containment)
            }
            let version = promotion.displayVersion ?? ""

            let status: EnvironmentStatus
            if answers.contains(false) {
                status = .awaiting(version: version)
            } else if answers.contains(nil) {
                status = .unknown
            } else {
                status = .carrying(version: version)
            }
            return EnvironmentState(
                environment: promotion.environment,
                status: status,
                regionsAgree: promotion.regionsAgree
            )
        }
    }

    /// Whether the release a region is running contains the merge.
    ///
    /// `nil` when nothing identifies that version, or when the comparison has
    /// not come back. A release cut before the merge is settled from the clock
    /// alone, without spending a request.
    private static func carries(
        pr: MergedPullRequest,
        version: String,
        releases: [Release],
        containment: [ContainmentKey: Bool]
    ) -> Bool? {
        guard let release = releases.first(where: { ReleaseVersion.strip($0.tagName) == version })
        else { return nil }
        guard release.createdAt >= pr.mergedAt else { return false }
        return containment[ContainmentKey(pullRequestID: pr.id, tagName: release.tagName)]
    }

    private static func status(
        for pr: MergedPullRequest,
        releases: [Release],
        containment: [ContainmentKey: Bool]
    ) -> ShipStatus {
        guard let oid = pr.mergeCommitOid, !oid.isEmpty else { return .pending }

        let link = WorkflowLink.pick(from: pr.contexts, fallback: pr.url)

        // The rollup is the authority rather than a tally of `contexts`: it
        // covers context types this app drops, so a failure it cannot name is
        // still one it knows about. A named failing check counts too, in case
        // the two ever disagree — evidence outranks a summary.
        if let failing = failingContext(in: pr.contexts) {
            return .failed(name: failing.name, url: link)
        }
        switch pr.rollupState {
        case .failure, .error:
            return .failed(name: failingName(in: pr.contexts), url: link)
        case .pending, .expected:
            return .building(link)
        case .success, nil:
            break
        }

        if let version = firstContaining(pr: pr, releases: releases, containment: containment) {
            return .released(version: version.tagName, url: version.url)
        }

        // Checks are green (or absent) but no release carries the change yet.
        // A repository that cuts no releases at all has nothing pending, so it
        // rests at `.pending` rather than claiming to be mid-flight forever.
        return releases.isEmpty ? .pending : .building(link)
    }

    /// The earliest release that contains the merge, which is the version the
    /// change first appeared in — not the newest one that happens to include it.
    private static func firstContaining(
        pr: MergedPullRequest,
        releases: [Release],
        containment: [ContainmentKey: Bool]
    ) -> Release? {
        releases
            .sorted { $0.createdAt < $1.createdAt }
            .first { containment[ContainmentKey(pullRequestID: pr.id, tagName: $0.tagName)] == true }
    }

    private static func failingContext(in contexts: [CheckContext]) -> CheckContext? {
        contexts.first { $0.state == .failure || $0.state == .error }
    }

    /// Named where the rollup reports a failure no context accounts for — a
    /// context type this app dropped. "a check" is vague because the truth is.
    private static func failingName(in contexts: [CheckContext]) -> String {
        failingContext(in: contexts)?.name ?? "a check"
    }

    /// The promoted versions no release in hand accounts for.
    ///
    /// Whether an environment carries a change is decided among the releases
    /// actually fetched, and the window's depth reaches only the most recent few.
    /// An environment lagging further behind than that is unanswerable — which
    /// renders as no chip rather than as a lag, and for a repository shipping
    /// several times a day production is always in that position.
    ///
    /// Deduplicated per repository and version: every merge in a repository sees
    /// the same environments, and one version is one release however many regions
    /// are on it.
    public static func unidentifiedVersions(
        merged: [MergedPullRequest],
        releases: [String: [Release]],
        promotions: [String: [PromotedVersion]]
    ) -> [ReleaseTagRequest] {
        var seen: Set<ReleaseTagRequest> = []
        return merged.flatMap { pr -> [ReleaseTagRequest] in
            let identified = Set(
                (releases[pr.repositoryID] ?? []).map { ReleaseVersion.strip($0.tagName) }
            )
            return (promotions[pr.repo] ?? []).compactMap { promotion in
                guard !identified.contains(promotion.version) else { return nil }
                let request = ReleaseTagRequest(
                    repo: pr.repo, repositoryID: pr.repositoryID, version: promotion.version
                )
                return seen.insert(request).inserted ? request : nil
            }
        }
    }

    /// The (pull request, release) pairs worth a containment request.
    ///
    /// A release cut before the merge cannot contain it, so asking would spend a
    /// request to be told what the clock already says.
    public static func candidates(
        merged: [MergedPullRequest],
        releases: [String: [Release]]
    ) -> [ContainmentCandidate] {
        merged.flatMap { pr -> [ContainmentCandidate] in
            guard pr.mergeCommitOid != nil else { return [] }
            return (releases[pr.repositoryID] ?? [])
                .filter { $0.createdAt >= pr.mergedAt }
                .sorted { $0.createdAt < $1.createdAt }
                .map { ContainmentCandidate(pullRequest: pr, release: $0) }
        }
    }
}

/// Chooses where a merged row goes when it is clicked.
public enum WorkflowLink {

    /// Prefers a whole CircleCI workflow over one job inside it, and among
    /// equals prefers the one the user would want to look at: still running
    /// first, then failing.
    ///
    /// - Parameter fallback: used when nothing carries a URL. A row that does
    ///   nothing when clicked is worse than one that opens the pull request.
    public static func pick(from contexts: [CheckContext], fallback: URL) -> URL {
        let linked = contexts.filter { $0.url != nil }
        let preferred = linked.filter(\.isWorkflow).isEmpty ? linked : linked.filter(\.isWorkflow)

        let running = preferred.first { $0.state == .pending || $0.state == .expected }
        let failing = preferred.first { $0.state == .failure || $0.state == .error }

        return (running ?? failing ?? preferred.first)?.url ?? fallback
    }
}
