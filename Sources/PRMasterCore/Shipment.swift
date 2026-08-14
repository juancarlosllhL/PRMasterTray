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

/// A merged pull request together with what became of it.
public struct Shipment: Identifiable, Sendable, Equatable {
    public let pr: MergedPullRequest
    public let status: ShipStatus

    public var id: String { pr.id }

    public init(pr: MergedPullRequest, status: ShipStatus) {
        self.pr = pr
        self.status = status
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
    public static func resolve(
        merged: [MergedPullRequest],
        releases: [String: [Release]],
        containment: [ContainmentKey: Bool]
    ) -> [Shipment] {
        merged.map { pr in
            Shipment(
                pr: pr,
                status: status(for: pr, releases: releases[pr.repositoryID] ?? [], containment: containment)
            )
        }
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
