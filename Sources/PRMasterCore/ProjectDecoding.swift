import Foundation

public struct ProjectItemPage: Sendable, Equatable {
    public let items: [ProjectItem]
    /// The cursor for the next page, nil on the last one.
    public let next: String?
}

public enum ProjectDecoder {

    /// Every open project found by any route, once each, sorted by title.
    public static func decodeProjects(_ data: Data) throws -> [GitHubProject] {
        let viewer = try envelope(ProjectsPayload.self, from: data).viewer
        let organizations = viewer.organizations.nodes?.compactMap { $0 } ?? []
        let found = (viewer.projectsV2.nodes ?? [])
            + organizations.flatMap { ($0.recentProjects?.nodes ?? []) + ($0.projects?.nodes ?? []) }

        var seen: Set<String> = []
        return found.compactMap { $0 }
            .filter { !$0.closed && seen.insert($0.id).inserted }
            .map(\.domain)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public static func decodeLogin(_ data: Data) throws -> String {
        try envelope(ViewerPayload.self, from: data).viewer.login
    }

    /// Drafts have no repository or URL, and a redacted item has no content at
    /// all, so neither becomes an item.
    public static func decodeItems(_ data: Data, projectID: String) throws -> ProjectItemPage {
        let payload = try envelope(ProjectItemsPayload.self, from: data)
        guard let items = payload.node?.items else {
            throw PRMasterError.decoding("project \(projectID) answered with no items")
        }
        return ProjectItemPage(
            items: (items.nodes ?? []).compactMap { $0?.domain(projectID: projectID) },
            next: items.pageInfo.hasNextPage ? items.pageInfo.endCursor : nil
        )
    }

    public static func decodeStatusUpdate(_ data: Data) throws {
        let payload = try envelope(StatusUpdatePayload.self, from: data)
        guard payload.updateProjectV2ItemFieldValue?.projectV2Item?.id != nil else {
            throw PRMasterError.decoding("GitHub never confirmed the move")
        }
    }

    /// Errors first: GitHub reports a missing scope as a 200 with a null payload.
    private static func envelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response: GraphQLResponse<T>
        do {
            response = try decoder.decode(GraphQLResponse<T>.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }
        if let errors = response.errors, !errors.isEmpty {
            if errors.contains(where: \.isMissingProjectScope) { throw PRMasterError.projectScopeMissing }
            throw PRMasterError.graphQL(errors.map(\.message))
        }
        guard let payload = response.data else {
            throw PRMasterError.decoding("response contained neither data nor errors")
        }
        return payload
    }
}

struct ProjectConnection<Node: Decodable>: Decodable {
    let nodes: [Node?]?
}

struct ProjectsPayload: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let projectsV2: ProjectConnection<ProjectNode>
        let organizations: ProjectConnection<Organization>
    }

    struct Organization: Decodable {
        let recentProjects: ProjectConnection<ProjectNode>?
        let projects: ProjectConnection<ProjectNode>?
    }
}

struct ViewerPayload: Decodable {
    let viewer: Viewer
    struct Viewer: Decodable { let login: String }
}

struct ProjectNode: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let closed: Bool
    let owner: Owner?
    /// Empty rather than null when a field named Status is not single-select.
    let field: Field?

    struct Owner: Decodable { let login: String? }

    struct Field: Decodable {
        let id: String?
        let options: [Option]?
    }

    struct Option: Decodable {
        let id: String
        let name: String
    }

    var domain: GitHubProject {
        GitHubProject(
            id: id, number: number, title: title, owner: owner?.login ?? "", url: url,
            statusFieldID: field?.id,
            options: field?.id == nil ? [] : (field?.options ?? []).map { StatusOption(id: $0.id, name: $0.name) }
        )
    }
}

struct ProjectItemsPayload: Decodable {
    let node: Node?

    struct Node: Decodable { let items: Items? }

    struct Items: Decodable {
        let pageInfo: PageInfo
        let nodes: [ProjectItemNode?]?
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

struct ProjectItemNode: Decodable {
    let id: String
    let status: Status?
    let content: Content?

    struct Status: Decodable {
        let optionId: String?
        let name: String?
        let updatedAt: Date?
    }

    struct Content: Decodable {
        let typename: String?
        let number: Int?
        let title: String?
        let url: URL?
        let createdAt: Date?
        let issueType: IssueType?
        let repository: Repository?
        let closedByPullRequestsReferences: IssueLinkSearchNode?

        struct IssueType: Decodable { let name: String? }
        struct Repository: Decodable { let nameWithOwner: String }

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case number, title, url, createdAt, issueType, repository
            case closedByPullRequestsReferences
        }
    }

    func domain(projectID: String) -> ProjectItem? {
        guard let content, content.typename == "Issue" || content.typename == "PullRequest",
              let number = content.number, let title = content.title, let url = content.url,
              let repo = content.repository?.nameWithOwner
        else { return nil }

        let isPullRequest = content.typename == "PullRequest"
        return ProjectItem(
            id: id, projectID: projectID, number: number, title: title, url: url, repo: repo,
            isPullRequest: isPullRequest,
            typeName: content.issueType?.name ?? (isPullRequest ? "Pull request" : "Issue"),
            statusOptionID: status?.optionId, statusName: status?.name,
            statusChangedAt: status?.updatedAt, createdAt: content.createdAt,
            links: content.closedByPullRequestsReferences?.nodes?.compactMap { $0?.domain } ?? []
        )
    }
}

struct StatusUpdatePayload: Decodable {
    let updateProjectV2ItemFieldValue: Result?

    struct Result: Decodable {
        let projectV2Item: Item?
        struct Item: Decodable { let id: String }
    }
}
