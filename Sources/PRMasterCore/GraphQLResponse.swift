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

/// Mirrors the nested search response so the domain model does not have to.
struct SearchPayload: Decodable {
    let search: SearchResults

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

        return payload.search.nodes.map(\.domain)
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
