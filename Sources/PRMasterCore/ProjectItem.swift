import Foundation

/// An issue or pull request on a GitHub Projects board. The same issue on two
/// boards is two items, each with its own Status.
public struct ProjectItem: Sendable, Equatable, Identifiable {
    /// The item's node id, which a move names, not the issue's.
    public let id: String
    public let projectID: String
    public let number: Int
    public let title: String
    public let url: URL
    /// `owner/name`.
    public let repo: String
    public let isPullRequest: Bool
    public let typeName: String
    public let statusOptionID: String?
    public let statusName: String?
    /// When the Status was last set, which is when the item reached Done.
    public let statusChangedAt: Date?
    public let createdAt: Date?
    /// The pull requests that close this issue. Always empty for a pull request.
    public let links: [LinkedPullRequest]

    /// The repository's name without its owner, as GitHub writes a reference.
    public var reference: String {
        "\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(number)"
    }

    public init(
        id: String, projectID: String, number: Int, title: String, url: URL, repo: String,
        isPullRequest: Bool, typeName: String, statusOptionID: String?, statusName: String?,
        statusChangedAt: Date?, createdAt: Date?, links: [LinkedPullRequest] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.number = number
        self.title = title
        self.url = url
        self.repo = repo
        self.isPullRequest = isPullRequest
        self.typeName = typeName
        self.statusOptionID = statusOptionID
        self.statusName = statusName
        self.statusChangedAt = statusChangedAt
        self.createdAt = createdAt
        self.links = links
    }

    public func with(status option: StatusOption, at date: Date) -> ProjectItem {
        ProjectItem(
            id: id, projectID: projectID, number: number, title: title, url: url, repo: repo,
            isPullRequest: isPullRequest, typeName: typeName, statusOptionID: option.id,
            statusName: option.name, statusChangedAt: date, createdAt: createdAt, links: links
        )
    }
}
