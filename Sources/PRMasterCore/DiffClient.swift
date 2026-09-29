import Foundation

public struct PullRequestDiff: Sendable, Equatable {
    public let pullRequestID: String
    public let baseOid: String
    /// What Merge and Approve are pinned to.
    public let headOid: String
    public var files: [DiffFile]
    /// GitHub lists at most 3000 files; the rest cannot be shown.
    public let isTruncated: Bool
    /// The root `.gitattributes` at the head, or nil when absent or unreadable.
    public var gitAttributes: String?

    public init(
        pullRequestID: String, baseOid: String, headOid: String, files: [DiffFile], isTruncated: Bool,
        gitAttributes: String? = nil
    ) {
        self.pullRequestID = pullRequestID
        self.baseOid = baseOid
        self.headOid = headOid
        self.files = files
        self.isTruncated = isTruncated
        self.gitAttributes = gitAttributes
    }
}

public protocol PullRequestDiffing: Sendable {
    func loadDiff(repo: String, number: Int) async throws -> PullRequestDiff
    func setViewed(pullRequestID: String, path: String, viewed: Bool) async throws
}

extension GitHubClient: PullRequestDiffing {

    static let compareFileLimit = 300
    static let pullFileLimit = 3000
    static let filesPerPage = 100

    public func loadDiff(repo: String, number: Int) async throws -> PullRequestDiff {
        var diff: PullRequestDiff
        do {
            diff = try await readDiff(repo: repo, number: number)
        } catch PRMasterError.diffHeadMoved {
            diff = try await readDiff(repo: repo, number: number)
        }
        // Only sorts files into sections, so losing it must not cost the diff.
        diff.gitAttributes = try? await gitAttributes(repo: repo, at: diff.headOid)
        return diff
    }

    private func gitAttributes(repo: String, at oid: String) async throws -> String? {
        let variables: [String: GraphQLValue] = [
            "owner": .string(Self.owner(of: repo)), "name": .string(Self.name(of: repo)), "oid": .string(oid),
        ]
        return try DiffDecoder.decodeAttributes(try await perform(query: Queries.diffAttributes, variables: variables))
    }

    public func setViewed(pullRequestID: String, path: String, viewed: Bool) async throws {
        let data = try await perform(
            query: viewed ? Queries.markFileViewed : Queries.unmarkFileViewed,
            variables: ["id": .string(pullRequestID), "path": .string(path)]
        )
        try DiffDecoder.checkViewedMutation(data)
    }

    private func readDiff(repo: String, number: Int) async throws -> PullRequestDiff {
        let meta = try await diffMeta(repo: repo, number: number)
        var files: [DiffFile]
        if meta.changedFiles <= Self.compareFileLimit {
            // Pinned by SHA, so a push after the metadata read cannot change it.
            let url = URL(string: "https://api.github.com/repos/\(repo)/compare/\(meta.baseOid)...\(meta.headOid)")!
            files = try DiffDecoder.compareFiles(try await get(url))
        } else {
            files = try await pagedFiles(repo: repo, number: number)
            guard try await currentHead(repo: repo, number: number) == meta.headOid else {
                throw PRMasterError.diffHeadMoved
            }
        }

        for index in files.indices {
            files[index].viewed = meta.viewed[files[index].path] ?? .unviewed
        }
        return PullRequestDiff(
            pullRequestID: meta.id, baseOid: meta.baseOid, headOid: meta.headOid,
            files: files, isTruncated: meta.changedFiles > Self.pullFileLimit
        )
    }

    private func diffMeta(repo: String, number: Int) async throws -> DiffMeta {
        var after: String?
        var meta: DiffMeta?
        repeat {
            var variables = diffVariables(repo: repo, number: number)
            if let after { variables["after"] = .string(after) }
            let page = try DiffDecoder.decodeMeta(try await perform(query: Queries.diffMeta, variables: variables))
            if meta == nil { meta = page } else { meta?.viewed.merge(page.viewed) { $1 } }
            after = page.nextCursor
        } while after != nil && (meta?.viewed.count ?? 0) < Self.pullFileLimit
        return meta!
    }

    private func pagedFiles(repo: String, number: Int) async throws -> [DiffFile] {
        var files: [DiffFile] = []
        for page in 1...(Self.pullFileLimit / Self.filesPerPage) {
            var components = URLComponents(string: "https://api.github.com/repos/\(repo)/pulls/\(number)/files")!
            components.queryItems = [
                URLQueryItem(name: "per_page", value: String(Self.filesPerPage)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            let batch = try DiffDecoder.pullFiles(try await get(components.url!))
            files += batch
            if batch.count < Self.filesPerPage { break }
        }
        return files
    }

    private func currentHead(repo: String, number: Int) async throws -> String {
        let data = try await perform(query: Queries.diffHead, variables: diffVariables(repo: repo, number: number))
        return try DiffDecoder.decodeHead(data)
    }

    private func diffVariables(repo: String, number: Int) -> [String: GraphQLValue] {
        ["owner": .string(Self.owner(of: repo)), "name": .string(Self.name(of: repo)), "number": .int(number)]
    }
}

struct DiffMeta {
    let id: String
    let baseOid: String
    let headOid: String
    let changedFiles: Int
    var viewed: [String: ViewedState]
    let nextCursor: String?
}

extension DiffDecoder {

    static func decodeMeta(_ data: Data) throws -> DiffMeta {
        let pull = try pullRequest(MetaPayload.self, data)
        let nodes = pull.files?.nodes ?? []
        return DiffMeta(
            id: pull.id, baseOid: pull.baseRefOid, headOid: pull.headRefOid, changedFiles: pull.changedFiles,
            viewed: Dictionary(
                nodes.map { ($0.path, ViewedState(rawValue: $0.viewerViewedState) ?? .unviewed) },
                uniquingKeysWith: { $1 }
            ),
            nextCursor: pull.files?.pageInfo.hasNextPage == true ? pull.files?.pageInfo.endCursor : nil
        )
    }

    /// Lenient on errors: GitHub reports a missing file as NOT_FOUND beside null data.
    static func decodeAttributes(_ data: Data) throws -> String? {
        do {
            return try JSONDecoder().decode(GraphQLResponse<AttributesPayload>.self, from: data)
                .data?.repository?.object?.file?.object?.text
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }
    }

    static func decodeHead(_ data: Data) throws -> String {
        try pullRequest(HeadPayload.self, data).headRefOid
    }

    static func checkViewedMutation(_ data: Data) throws {
        let response = try graphQL([String: ClientMutation?].self, data)
        guard response.values.contains(where: { $0 != nil }) else {
            throw PRMasterError.graphQL(["GitHub did not confirm the file's viewed state."])
        }
    }

    private static func pullRequest<P: Decodable>(_ type: P.Type, _ data: Data) throws -> P {
        guard let pull = try graphQL(Repository<P>.self, data).repository?.pullRequest else {
            throw PRMasterError.decoding("pull request not found")
        }
        return pull
    }

    private static func graphQL<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let response: GraphQLResponse<T>
        do {
            response = try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)
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

    private struct AttributesPayload: Decodable {
        struct Blob: Decodable { let text: String? }
        struct Entry: Decodable { let object: Blob? }
        struct Commit: Decodable { let file: Entry? }
        struct Repo: Decodable { let object: Commit? }
        let repository: Repo?
    }

    private struct Repository<P: Decodable>: Decodable {
        struct Inner: Decodable { let pullRequest: P? }
        let repository: Inner?
    }

    private struct MetaPayload: Decodable {
        struct Files: Decodable {
            struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
            struct Node: Decodable { let path: String; let viewerViewedState: String }
            let pageInfo: PageInfo
            let nodes: [Node]
        }
        let id: String
        let baseRefOid: String
        let headRefOid: String
        let changedFiles: Int
        let files: Files?
    }

    private struct HeadPayload: Decodable {
        let headRefOid: String
    }

    private struct ClientMutation: Decodable {
        let clientMutationId: String?
    }
}
