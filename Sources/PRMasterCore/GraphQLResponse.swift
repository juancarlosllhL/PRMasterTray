import Foundation

/// A GitHub GraphQL enum that survives values added after this app was built.
///
/// GitHub extends its enums over time. A strict `Decodable` would throw on the
/// first unfamiliar string and blank the entire PR list, so every enum degrades
/// to a deliberately chosen fallback instead.
protocol UnknownTolerantEnum: RawRepresentable, Decodable where RawValue == String {
    /// Must be the *safest* interpretation, never the most optimistic one.
    static var unknownFallback: Self { get }
}

extension UnknownTolerantEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownFallback
    }
}

extension Mergeable: UnknownTolerantEnum {
    static var unknownFallback: Mergeable { .unknown }
}

extension MergeStateStatus: UnknownTolerantEnum {
    static var unknownFallback: MergeStateStatus { .unknown }
}

extension ReviewDecision: UnknownTolerantEnum {
    /// Assume a review is still needed rather than that one was granted.
    static var unknownFallback: ReviewDecision { .reviewRequired }
}

extension CheckState: UnknownTolerantEnum {
    /// Assume checks are still running. Falling back to `success` would let an
    /// unrecognised state promote a PR to ready and fire a false notification.
    static var unknownFallback: CheckState { .pending }
}

extension CheckRunStatus: UnknownTolerantEnum {
    /// Anything unfamiliar is treated as not finished, which `CheckContext`
    /// reads as pending regardless of the conclusion beside it.
    static var unknownFallback: CheckRunStatus { .inProgress }
}

extension CheckConclusion: UnknownTolerantEnum {
    /// Same rule as `CheckState`, with more at stake: an unrecognised
    /// conclusion read as `success` would claim a change had shipped on no
    /// evidence at all.
    static var unknownFallback: CheckConclusion { .unknown }
}

/// A value bound to a GraphQL variable.
///
/// An enum rather than `Any` because it is the mechanism that keeps remote
/// strings out of query text: everything the app sends GitHub travels through
/// here as a typed value, so there is no path by which a tag name could end up
/// concatenated into a document.
public enum GraphQLValue: Sendable, Equatable {
    case string(String)
    /// A list of node IDs, for `nodes(ids:)`.
    case ids([String])
    /// A page size, for `first:`.
    case int(Int)

    var jsonObject: Any {
        switch self {
        case .string(let value): return value
        case .ids(let values):   return values
        case .int(let value):    return value
        }
    }
}

/// One poll's answer: the open pull requests and the recently merged ones,
/// decoded from a single response so the two always describe the same moment.
public struct PullRequestSnapshot: Sendable, Equatable {
    public let open: [PullRequest]
    public let merged: [MergedPullRequest]

    public init(open: [PullRequest], merged: [MergedPullRequest]) {
        self.open = open
        self.merged = merged
    }
}

/// GraphQL envelope. `data` and `errors` can both be present: GitHub returns
/// partial data alongside errors, and always with HTTP 200.
struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let message: String
}

// MARK: - Wire shape

/// Mirrors the `open:` half of the dual-aliased search so the domain model does
/// not have to. The `merged:` half is `MergedSearchPayload`; each ignores the
/// other's key, which is what lets one response feed both.
struct SearchPayload: Decodable {
    let open: SearchResults

    struct SearchResults: Decodable {
        let nodes: [Node]
    }

    struct Node: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let isDraft: Bool
        let headRefOid: String
        let updatedAt: Date
        let createdAt: Date
        let mergeable: Mergeable
        let mergeStateStatus: MergeStateStatus
        let reviewDecision: ReviewDecision?
        let repository: Repository
        let commits: Commits
        let reviews: Reviews

        struct Repository: Decodable {
            let nameWithOwner: String
            let isPrivate: Bool
        }

        struct Reviews: Decodable { let totalCount: Int }

        struct Commits: Decodable {
            let nodes: [CommitNode]
            struct CommitNode: Decodable {
                let commit: Commit
                struct Commit: Decodable {
                    /// `null` when the repo has no CI configured at all.
                    let statusCheckRollup: Rollup?
                    struct Rollup: Decodable { let state: CheckState }
                }
            }
        }

        var domain: PullRequest {
            PullRequest(
                id: id,
                number: number,
                title: title,
                url: url,
                repo: repository.nameWithOwner,
                isPrivate: repository.isPrivate,
                isDraft: isDraft,
                headRefOid: headRefOid,
                mergeable: mergeable,
                mergeState: mergeStateStatus,
                reviewDecision: reviewDecision,
                // Absent rollup stays nil: "no CI" is not "checks running".
                checks: commits.nodes.first?.commit.statusCheckRollup?.state,
                approvals: reviews.totalCount,
                updatedAt: updatedAt,
                createdAt: createdAt
            )
        }
    }
}

/// Mirrors the `merged:` half of the dual-aliased search. The `open:` half is
/// decoded by `SearchPayload`; each ignores the other's key, which is what lets
/// one response feed both without either knowing about the other.
struct MergedSearchPayload: Decodable {
    let merged: Results

    struct Results: Decodable {
        let nodes: [Node]
    }

    struct Node: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let mergedAt: Date
        let repository: Repository
        /// `null` for the few seconds before GitHub materialises the commit.
        let mergeCommit: MergeCommit?

        struct Repository: Decodable {
            /// The node ID, unlike the open-PR shape, which needs only the name.
            let id: String
            let nameWithOwner: String
            let isPrivate: Bool
        }

        struct MergeCommit: Decodable {
            let oid: String
            /// `null` when the repository has no CI configured at all.
            let statusCheckRollup: Rollup?

            struct Rollup: Decodable {
                let state: CheckState
                let contexts: Contexts

                struct Contexts: Decodable {
                    let nodes: [ContextNode]
                }
            }
        }

        var domain: MergedPullRequest {
            MergedPullRequest(
                id: id,
                number: number,
                title: title,
                url: url,
                repo: repository.nameWithOwner,
                repositoryID: repository.id,
                isPrivate: repository.isPrivate,
                mergedAt: mergedAt,
                mergeCommitOid: mergeCommit?.oid,
                rollupState: mergeCommit?.statusCheckRollup?.state,
                contexts: mergeCommit?.statusCheckRollup?
                    .contexts.nodes.compactMap(\.domain) ?? []
            )
        }
    }
}

/// One arm of GitHub's `StatusCheckRollupContext` union.
///
/// Every field is optional because only half of them are present on any given
/// node, and which half depends on `__typename`. The union has exactly two arms
/// today; an arm added later decodes to `nil` and drops out, which is safe only
/// because `MergedPullRequest.rollupState` still counts it.
struct ContextNode: Decodable {
    let typename: String
    let name: String?
    let status: CheckRunStatus?
    let conclusion: CheckConclusion?
    let detailsUrl: URL?
    let context: String?
    let state: CheckState?
    let targetUrl: URL?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name, status, conclusion, detailsUrl, context, state, targetUrl
    }

    var domain: CheckContext? {
        switch typename {
        case "CheckRun":
            guard let name else { return nil }
            return CheckContext(
                name: name,
                state: CheckContext.state(status: status, conclusion: conclusion),
                url: detailsUrl,
                isWorkflow: true
            )
        case "StatusContext":
            guard let context, let state else { return nil }
            return CheckContext(
                name: context,
                state: state,
                url: targetUrl,
                isWorkflow: false
            )
        default:
            return nil
        }
    }
}

/// One poll's answer about the user's teams: the rows, and how many are pending
/// per team.
///
/// The counts are kept beside the rows rather than derived from them, because
/// they are not derivable: a team the user has switched off is asked at
/// `first: 0`, so it contributes a count and no rows at all. That count is what
/// the settings list needs in order to say what switching the team on would cost.
public struct ReviewSnapshot: Sendable, Equatable {
    /// Deduplicated across teams and ordered by last activity, newest first.
    public let requests: [ReviewRequest]
    /// Keyed by `Team.combinedSlug`. A team GitHub did not answer for is absent
    /// rather than zero — not knowing is not the same as none.
    public let pendingCounts: [String: Int]

    public init(requests: [ReviewRequest], pendingCounts: [String: Int]) {
        self.requests = requests
        self.pendingCounts = pendingCounts
    }

    public static let empty = ReviewSnapshot(requests: [], pendingCounts: [:])
}

/// One `s{n}: search { issueCount nodes }` answer.
struct ReviewSearchNode: Decodable {
    let issueCount: Int
    let nodes: [Node]

    struct Node: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let headRefOid: String
        let createdAt: Date
        let updatedAt: Date
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let reviewDecision: ReviewDecision?
        /// `null` when the account that opened it has been deleted — GitHub
        /// reassigns their pull requests to nobody.
        let author: Author?
        let repository: Repository
        let commits: Commits
        let viewerLatestReview: LatestReview?
        let timelineItems: TimelineItems?

        struct Author: Decodable { let login: String }

        struct LatestReview: Decodable { let state: PullRequestReviewState }

        struct TimelineItems: Decodable {
            let nodes: [Event]
            /// A person's request decodes as an empty object: the query selects
            /// `combinedSlug` on `Team` and nothing else.
            struct Event: Decodable {
                let requestedReviewer: Reviewer?
                struct Reviewer: Decodable { let combinedSlug: String? }
            }
        }

        struct Repository: Decodable {
            let nameWithOwner: String
            let isPrivate: Bool
        }

        struct Commits: Decodable {
            let nodes: [CommitNode]
            struct CommitNode: Decodable {
                let commit: Commit
                struct Commit: Decodable {
                    /// `null` when the repository has no CI configured at all.
                    let statusCheckRollup: Rollup?
                    struct Rollup: Decodable { let state: CheckState }
                }
            }
        }

        func teamsAsked(from teams: [Team]) -> [Team] {
            let asked = Set((timelineItems?.nodes ?? []).compactMap {
                $0.requestedReviewer?.combinedSlug
            })
            return teams.filter { asked.contains($0.combinedSlug) }
        }

        func domain(teams: [Team], viewerReviewDismissed: Bool = false) -> ReviewRequest {
            ReviewRequest(
                id: id,
                number: number,
                title: title,
                url: url,
                repo: repository.nameWithOwner,
                isPrivate: repository.isPrivate,
                // The pull request is real and still needs reviewing, so a
                // deleted author must not lose the row. `ghost` is GitHub's own
                // name for the account it reassigns their content to, which
                // makes it the one placeholder that is not invented here.
                author: author?.login ?? "ghost",
                headRefOid: headRefOid,
                // Absent rollup stays nil: "no CI" is not "checks running".
                checks: commits.nodes.first?.commit.statusCheckRollup?.state,
                reviewDecision: reviewDecision,
                createdAt: createdAt,
                updatedAt: updatedAt,
                additions: additions,
                deletions: deletions,
                changedFiles: changedFiles,
                teams: teams,
                viewerReviewDismissed: viewerReviewDismissed
            )
        }
    }
}

/// One row under construction: the first alias to return it wins its fields,
/// and the teams accumulate across every alias that did.
private struct Row {
    let node: ReviewSearchNode.Node
    let teams: [Team]
    let dismissed: Bool

    func adding(_ team: Team) -> Row {
        Row(node: node, teams: teams + [team], dismissed: dismissed)
    }

    func dismissing() -> Row {
        Row(node: node, teams: teams, dismissed: true)
    }
}

/// Mirrors the two role-filtered team lists per organization.
///
/// Both lists are present because one is not enough — see `Queries.myTeams`.
struct TeamsPayload: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let organizations: Organizations

        struct Organizations: Decodable {
            /// `null` for an organization GitHub declines to resolve. One of those
            /// must not take the other organizations' teams down with it — the
            /// rule `ReleasesPayload` follows for a repository deleted between
            /// two calls.
            let nodes: [Node?]

            struct Node: Decodable {
                let login: String
                let member: TeamList
                let admin: TeamList

                struct TeamList: Decodable {
                    let nodes: [TeamNode]

                    struct TeamNode: Decodable {
                        let name: String
                        let combinedSlug: String
                    }
                }

                /// Both roles, in the order the query declares them. Deduplicated
                /// by the caller rather than here, because a team can appear in
                /// both lists and the duplicate is only visible across them.
                var teams: [Team] {
                    (member.nodes + admin.nodes).map {
                        Team(
                            combinedSlug: $0.combinedSlug,
                            organization: login,
                            name: $0.name
                        )
                    }
                }
            }
        }
    }
}

struct ReleasesPayload: Decodable {
    /// `null` for a node GitHub could not resolve — a repository that was
    /// deleted or renamed between the search and this lookup. One of those must
    /// not take the others' releases down with it.
    let nodes: [Node?]

    struct Node: Decodable {
        let id: String
        let releases: Releases

        struct Releases: Decodable {
            let nodes: [ReleaseNode]

            struct ReleaseNode: Decodable {
                let tagName: String
                let url: URL
                let createdAt: Date
                let isDraft: Bool
                /// `null` when the tag points at something other than a commit.
                let tagCommit: Commit?

                struct Commit: Decodable { let oid: String }

                /// Drafts are excluded: nothing is running a release that was
                /// never published, so calling a change shipped in one is false.
                var domain: Release? {
                    guard !isDraft, let tagCommit else { return nil }
                    return Release(
                        tagName: tagName,
                        url: url,
                        tagCommitOid: tagCommit.oid,
                        createdAt: createdAt
                    )
                }
            }
        }
    }
}

/// GitHub `ComparisonStatus`.
enum CompareStatus: String, Sendable, CaseIterable {
    case ahead = "AHEAD"
    case behind = "BEHIND"
    case diverged = "DIVERGED"
    case identical = "IDENTICAL"
    case unknown

    /// Whether the tag being compared *contains* the commit.
    ///
    /// The comparison is made from the tag as base to the merge commit as head,
    /// so a head that is `behind` the tag is an ancestor of it — which is
    /// exactly what "this release includes my change" means. `nil` for a status
    /// this app does not recognise, which the resolver treats as no answer
    /// rather than as a no.
    var contains: Bool? {
        switch self {
        case .behind, .identical: return true
        case .ahead, .diverged:   return false
        case .unknown:            return nil
        }
    }
}

extension CompareStatus: UnknownTolerantEnum {
    static var unknownFallback: CompareStatus { .unknown }
}

struct FileTextPayload: Decodable {
    let repository: Repository?

    struct Repository: Decodable {
        let object: Blob?
        struct Blob: Decodable { let text: String? }
    }
}

/// One code-search hit, in the shape GitHub's REST search returns.
struct CodeSearchPayload: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let path: String
        let repository: Repository

        struct Repository: Decodable { let fullName: String }
    }
}

/// One `t{n}: repository { object { entries } }` answer.
struct PromotionTreeNode: Decodable {
    /// `null` when the app folder does not resolve at HEAD.
    let object: Tree?

    struct Tree: Decodable {
        let entries: [Entry]?

        struct Entry: Decodable {
            let name: String
            /// `null` for an entry with no addressable content.
            let object: Content?

            struct Content: Decodable { let oid: String }

            var domain: TreeEntry? {
                object.map { TreeEntry(name: name, oid: $0.oid) }
            }
        }
    }
}

/// One `r{n}: repository { prefixed: release, bare: release }` answer.
struct TagReleaseNode: Decodable {
    /// `null` for a tag that does not exist. GitHub reports that as data rather
    /// than as an error, which is what lets both spellings be asked at once.
    let prefixed: ReleasesPayload.Node.Releases.ReleaseNode?
    let bare: ReleasesPayload.Node.Releases.ReleaseNode?

    /// The prefixed spelling first, because that is what these repositories tag
    /// with. Either way it goes through `domain`, so a draft is excluded here on
    /// the same terms as everywhere else.
    var domain: Release? { prefixed?.domain ?? bare?.domain }
}

/// One `b{n}: repository { object { text } }` answer.
struct PromotionBlobNode: Decodable {
    /// `null` when the path does not resolve, and `text` is itself null for a
    /// binary blob.
    let object: Blob?

    struct Blob: Decodable { let text: String? }
}

/// One `t{n}: repository { ref { compare } }` answer.
struct ContainmentNode: Decodable {
    /// `null` when GitHub cannot resolve the tag.
    let ref: Ref?

    struct Ref: Decodable {
        let compare: Compare?
        struct Compare: Decodable { let status: CompareStatus }
    }
}

// MARK: - Entry point

public enum PullRequestDecoder {
    /// Decodes a PR search response.
    ///
    /// - Throws: `.graphQL` when the body carries an `errors` array, even on
    ///   HTTP 200, and `.decoding` when the body cannot be parsed at all.
    public static func decodeSearch(_ data: Data) throws -> [PullRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response: GraphQLResponse<SearchPayload>
        do {
            response = try decoder.decode(GraphQLResponse<SearchPayload>.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        // Checked before `data`: GitHub reports SSO failures as a 200 with a
        // null payload, which would otherwise look like "no open PRs".
        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.graphQL(errors.map(\.message))
        }

        guard let payload = response.data else {
            throw PRMasterError.decoding("response contained neither data nor errors")
        }

        return payload.open.nodes.map(\.domain)
    }

    /// Decodes the merged half of the same search response.
    ///
    /// - Throws: `.graphQL` when the body carries an `errors` array, and
    ///   `.decoding` when the body cannot be parsed at all — the same contract
    ///   as `decodeSearch`, and for the same reason: a null payload behind a 200
    ///   must not read as "nothing merged".
    public static func decodeMergedSearch(_ data: Data) throws -> [MergedPullRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response: GraphQLResponse<MergedSearchPayload>
        do {
            response = try decoder.decode(
                GraphQLResponse<MergedSearchPayload>.self, from: data
            )
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.graphQL(errors.map(\.message))
        }

        guard let payload = response.data else {
            throw PRMasterError.decoding("response contained neither data nor errors")
        }

        return payload.merged.nodes.map(\.domain)
    }

    /// Decodes every team the user belongs to, unioned across both viewer roles.
    ///
    /// Deduplicated by `combinedSlug`: nothing documents the two role lists as
    /// disjoint, and the same team in both would be searched twice and listed
    /// twice in settings. Sorted, because the settings list reads in this order
    /// and the search assigns its aliases in it — GitHub's own order is not
    /// promised to be stable.
    ///
    /// An empty result is a real answer: being in no teams is not a failure.
    ///
    /// - Throws: `.graphQL` when the body carries an `errors` array. Checked
    ///   before `data` for the usual reason, which bites harder here than
    ///   anywhere else: GitHub reports both a SAML SSO refusal and a missing
    ///   `read:org` scope as a 200 with a null payload, and reading that as an
    ///   empty list would tell the user they belong to no teams — leaving them no
    ///   reason to go and fix the scope.
    public static func decodeTeams(_ data: Data) throws -> [Team] {
        let response: GraphQLResponse<TeamsPayload>
        do {
            response = try JSONDecoder().decode(GraphQLResponse<TeamsPayload>.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.graphQL(errors.map(\.message))
        }

        guard let payload = response.data else {
            throw PRMasterError.decoding("response contained neither data nor errors")
        }

        let teams = payload.viewer.organizations.nodes.compactMap { $0 }.flatMap(\.teams)
        var seen: Set<String> = []
        return teams
            .filter { seen.insert($0.combinedSlug).inserted }
            .sorted {
                $0.combinedSlug.localizedCaseInsensitiveCompare($1.combinedSlug)
                    == .orderedAscending
            }
    }

    /// Decodes the per-team review searches into one flat, deduplicated list.
    ///
    /// Aliases are `s0…sN` in team order, plus `Queries.dismissalAlias`, the
    /// contract `Queries.reviewRequests(for:filter:window:now:)` establishes.
    ///
    /// Deduplicated by pull request ID, carrying every team that was asked. A
    /// pull request requested from two of the user's teams comes back under two
    /// aliases — seen live on a repository asked of both `platform` and
    /// `datanauts` — and rendering it twice is the visible bug that motivates
    /// this. The teams on a shared row follow the caller's team order rather than
    /// the order the aliases were read in, so the row is stable.
    ///
    /// Ordered by `updatedAt` descending: flat and most-recently-active first, so
    /// the list does not depend on which team happened to be searched first.
    ///
    /// A team GitHub did not answer for is omitted from the counts rather than
    /// recorded as zero. Zero would tell the settings list that a team has
    /// nothing waiting, which is a claim a missing answer does not support.
    ///
    /// - Throws: `.graphQL` when the body carries an `errors` array, checked
    ///   before `data` because GitHub reports an SSO refusal as a 200 with a null
    ///   payload — which would otherwise read as nothing waiting on any team.
    public static func decodeReviewRequests(
        _ data: Data,
        teams: [Team]
    ) throws -> ReviewSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try aliased(ReviewSearchNode.self, from: data, decoder: decoder)

        var counts: [String: Int] = [:]
        // Insertion-ordered so the teams on a deduplicated row keep the caller's
        // order, and so the first sighting of a pull request wins its fields.
        var order: [String] = []
        var byID: [String: Row] = [:]

        for (index, team) in teams.enumerated() {
            guard let search = payload["s\(index)"] ?? nil else { continue }
            counts[team.combinedSlug] = search.issueCount

            for node in search.nodes {
                if let existing = byID[node.id] {
                    byID[node.id] = existing.adding(team)
                } else {
                    order.append(node.id)
                    byID[node.id] = Row(node: node, teams: [team], dismissed: false)
                }
            }
        }

        for node in (payload[Queries.dismissalAlias] ?? nil)?.nodes ?? [] {
            guard node.viewerLatestReview?.state == .dismissed else { continue }
            let asked = node.teamsAsked(from: teams)
            guard !asked.isEmpty else { continue }

            if let existing = byID[node.id] {
                byID[node.id] = existing.dismissing()
            } else {
                order.append(node.id)
                byID[node.id] = Row(node: node, teams: asked, dismissed: true)
            }
        }

        let requests = order
            .compactMap { byID[$0] }
            .map { $0.node.domain(teams: $0.teams, viewerReviewDismissed: $0.dismissed) }
            .sorted { $0.updatedAt > $1.updatedAt }

        return ReviewSnapshot(requests: requests, pendingCounts: counts)
    }

    /// Decodes the releases of several repositories, keyed by node ID.
    public static func decodeReleases(_ data: Data) throws -> [String: [Release]] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response: GraphQLResponse<ReleasesPayload>
        do {
            response = try decoder.decode(GraphQLResponse<ReleasesPayload>.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.graphQL(errors.map(\.message))
        }

        guard let payload = response.data else {
            throw PRMasterError.decoding("response contained neither data nor errors")
        }

        return payload.nodes.compactMap { $0 }.reduce(into: [:]) { result, node in
            result[node.id] = node.releases.nodes.compactMap(\.domain)
        }
    }

    /// Decodes the containment answers, mapping each generated alias back to the
    /// candidate that produced it.
    ///
    /// Aliases are `t0…tN` in candidate order, which is the contract
    /// `Queries.containment(for:)` establishes and this relies on. A candidate
    /// with no answer is omitted rather than recorded as `false`: unknown and no
    /// are different, and only one of them is safe to act on.
    public static func decodeContainment(
        _ data: Data,
        candidates: [ContainmentCandidate]
    ) throws -> [ContainmentKey: Bool] {
        let response: GraphQLResponse<[String: ContainmentNode?]>
        do {
            response = try JSONDecoder().decode(
                GraphQLResponse<[String: ContainmentNode?]>.self, from: data
            )
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.graphQL(errors.map(\.message))
        }

        guard let payload = response.data else {
            throw PRMasterError.decoding("response contained neither data nor errors")
        }

        return candidates.enumerated().reduce(into: [:]) { result, pair in
            let (index, candidate) = pair
            guard let node = payload["t\(index)"] ?? nil,
                  let contains = node.ref?.compare?.status.contains else { return }
            result[candidate.key] = contains
        }
    }

    /// Decodes the entries of each app folder, mapping each generated alias back
    /// to the location that produced it.
    ///
    /// Aliases are `t0…tN` in location order, the contract
    /// `Queries.promotionTrees(for:)` establishes. A folder GitHub could not
    /// resolve is omitted rather than recorded as empty: an app whose tree failed
    /// to load has not been shown to have no promotions.
    public static func decodePromotionTrees(
        _ data: Data,
        locations: [AppLocation]
    ) throws -> [AppLocation: [TreeEntry]] {
        let payload = try aliased(PromotionTreeNode.self, from: data)

        return locations.enumerated().reduce(into: [:]) { result, pair in
            let (index, location) = pair
            guard let node = payload["t\(index)"] ?? nil, let entries = node.object?.entries
            else { return }
            result[location] = entries.compactMap(\.domain)
        }
    }

    /// Decodes the text of each values file, keyed by the oid it was asked for.
    ///
    /// Keyed by oid rather than by path because that is what the cache is keyed
    /// by, and because identical content anywhere is the same promoted version.
    /// A blob GitHub did not return is omitted rather than recorded as empty
    /// text, which would parse as an app with no promoted version at all.
    public static func decodePromotionBlobs(
        _ data: Data,
        requests: [BlobRequest]
    ) throws -> [String: String] {
        let payload = try aliased(PromotionBlobNode.self, from: data)

        return requests.enumerated().reduce(into: [:]) { result, pair in
            let (index, request) = pair
            guard let node = payload["b\(index)"] ?? nil, let text = node.object?.text
            else { return }
            result[request.oid] = text
        }
    }

    /// Decodes the release each promoted version names, keyed by the repository
    /// node ID the caller asked under.
    ///
    /// Aliases are `r0…rN` in request order. A version neither spelling of the
    /// tag resolves is omitted rather than recorded as a release with no commit:
    /// the resolver treats a missing release as unknown and says nothing, which
    /// is the difference between no answer and a wrong one.
    public static func decodeTagReleases(
        _ data: Data,
        requests: [ReleaseTagRequest]
    ) throws -> [String: [Release]] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try aliased(TagReleaseNode.self, from: data, decoder: decoder)

        return requests.enumerated().reduce(into: [:]) { result, pair in
            let (index, request) = pair
            guard let node = payload["r\(index)"] ?? nil, let release = node.domain
            else { return }
            result[request.repositoryID, default: []].append(release)
        }
    }

    /// The envelope handling every aliased response shares: errors first, because
    /// GitHub reports an SSO failure as a 200 with a null payload, which would
    /// otherwise read as nothing promoted anywhere.
    ///
    /// - Parameter decoder: the release payload carries dates, and the tree and
    ///   blob payloads do not, so the strategy comes from the caller.
    private static func aliased<Node: Decodable>(
        _ node: Node.Type,
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> [String: Node?] {
        let response: GraphQLResponse<[String: Node?]>
        do {
            response = try decoder.decode(GraphQLResponse<[String: Node?]>.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.graphQL(errors.map(\.message))
        }

        guard let payload = response.data else {
            throw PRMasterError.decoding("response contained neither data nor errors")
        }

        return payload
    }

    /// Decodes the text of a single file.
    ///
    /// `nil` when the file does not exist, which is not a failure: a repository
    /// with no CircleCI config simply cannot be joined to a deployments folder
    /// this way.
    public static func decodeFileText(_ data: Data) throws -> String? {
        let response: GraphQLResponse<FileTextPayload>
        do {
            response = try JSONDecoder().decode(GraphQLResponse<FileTextPayload>.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.graphQL(errors.map(\.message))
        }

        guard let payload = response.data else {
            throw PRMasterError.decoding("response contained neither data nor errors")
        }

        return payload.repository?.object?.text
    }

    /// Confirms a merge actually happened.
    ///
    /// - Throws: `.mergeRejected` with GitHub's own wording. A paraphrase would
    ///   hide *why* it failed, and "head branch was modified" is precisely the
    ///   case the user needs to understand.
    public static func decodeMerge(_ data: Data) throws {
        let response: GraphQLResponse<MergePayload>
        do {
            response = try JSONDecoder().decode(GraphQLResponse<MergePayload>.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.mergeRejected(
                errors.map(\.message).joined(separator: "\n")
            )
        }

        // A null payload or merged == false means GitHub declined without
        // reporting an error. Treating that as success would drop the PR from
        // the list while it is still open.
        guard response.data?.mergePullRequest?.pullRequest?.merged == true else {
            throw PRMasterError.mergeRejected("GitHub did not confirm the merge.")
        }
    }

    /// Confirms a pull request was actually closed.
    ///
    /// Insists on the state rather than trusting the absence of an `errors` array,
    /// which is the difference between this and the other two mutations. GitHub
    /// documents no error text for closing a pull request that is already closed,
    /// already merged, or in an archived repository, so "no errors" is not
    /// evidence of anything — only `CLOSED` is.
    ///
    /// - Throws: `.closeRejected` with GitHub's own wording where there is any.
    public static func decodeClose(_ data: Data) throws {
        let response: GraphQLResponse<ClosePayload>
        do {
            response = try JSONDecoder().decode(GraphQLResponse<ClosePayload>.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.closeRejected(
                errors.map(\.message).joined(separator: "\n")
            )
        }

        guard response.data?.closePullRequest?.pullRequest?.state == .closed else {
            throw PRMasterError.closeRejected("GitHub did not confirm the pull request was closed.")
        }
    }

    /// Confirms an approval was actually recorded.
    ///
    /// Insists on the state rather than trusting the absence of an `errors` array,
    /// the same rule `decodeClose` follows and for a sharper reason: GitHub will
    /// happily record a review that is not an approval, and treating that as
    /// success would drop the row from the list while leaving the user believing
    /// they had approved it.
    ///
    /// - Throws: `.approveRejected` with GitHub's own wording where there is any.
    ///   It gives good ones here — "Can not approve your own pull request" is the
    ///   one worth reading verbatim.
    public static func decodeApproval(_ data: Data) throws {
        let response: GraphQLResponse<ApprovalPayload>
        do {
            response = try JSONDecoder().decode(GraphQLResponse<ApprovalPayload>.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.approveRejected(
                errors.map(\.message).joined(separator: "\n")
            )
        }

        guard response.data?.addPullRequestReview?.pullRequestReview?.state == .approved else {
            throw PRMasterError.approveRejected("GitHub did not confirm the approval.")
        }
    }

    /// Confirms a branch update actually happened.
    ///
    /// - Throws: `.updateRejected` with GitHub's own wording. A null payload is
    ///   a refusal GitHub declined to explain; treating it as success would
    ///   record the attempt and strand the PR behind its base branch, because
    ///   the head oid the attempt is keyed on would never change.
    public static func decodeBranchUpdate(_ data: Data) throws {
        let response: GraphQLResponse<BranchUpdatePayload>
        do {
            response = try JSONDecoder().decode(
                GraphQLResponse<BranchUpdatePayload>.self, from: data
            )
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }

        if let errors = response.errors, !errors.isEmpty {
            throw PRMasterError.updateRejected(
                errors.map(\.message).joined(separator: "\n")
            )
        }

        guard response.data?.updatePullRequestBranch?.pullRequest != nil else {
            throw PRMasterError.updateRejected("GitHub did not confirm the branch update.")
        }
    }
}

/// GitHub `PullRequestState`.
///
/// Tolerant like the rest, and the fallback is the safe reading here too: an
/// unfamiliar state is not a confirmed close, so `decodeClose` treats it as a
/// refusal rather than reporting success for something it does not understand.
enum PullRequestState: String, Sendable, CaseIterable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
    case unknown
}

extension PullRequestState: UnknownTolerantEnum {
    static var unknownFallback: PullRequestState { .unknown }
}

/// GitHub `PullRequestReviewState`.
///
/// Tolerant like the rest, and the fallback is the safe reading here too: a state
/// this app does not recognise is not a confirmed approval, so `decodeApproval`
/// treats it as a refusal rather than reporting success for something it cannot
/// understand.
enum PullRequestReviewState: String, Sendable, CaseIterable {
    case pending = "PENDING"
    case commented = "COMMENTED"
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case dismissed = "DISMISSED"
    case unknown
}

extension PullRequestReviewState: UnknownTolerantEnum {
    static var unknownFallback: PullRequestReviewState { .unknown }
}

struct ApprovalPayload: Decodable {
    let addPullRequestReview: Result?

    struct Result: Decodable {
        let pullRequestReview: Review?
        struct Review: Decodable { let state: PullRequestReviewState }
    }
}

struct ClosePayload: Decodable {
    let closePullRequest: Result?

    struct Result: Decodable {
        let pullRequest: Closed?
        struct Closed: Decodable { let state: PullRequestState }
    }
}

struct BranchUpdatePayload: Decodable {
    let updatePullRequestBranch: Result?

    struct Result: Decodable {
        let pullRequest: Updated?
        struct Updated: Decodable { let id: String }
    }
}

struct MergePayload: Decodable {
    let mergePullRequest: Result?

    struct Result: Decodable {
        let pullRequest: Merged?
        struct Merged: Decodable { let merged: Bool }
    }
}
