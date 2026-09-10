import Foundation

/// Raw values are Jira's category *keys*, not the display names: the site
/// verified against returns key `new` under the name "To Do", so matching on
/// the name would break wherever a category is renamed or localised.
public enum JiraStatusCategory: String, Sendable, Equatable, CaseIterable {
    case toDo = "new"
    case inProgress = "indeterminate"
    case done = "done"
    case unknown = "__unknown"

    public var isDone: Bool { self == .done }

    public var label: String {
        switch self {
        case .toDo:       return "To do"
        case .inProgress: return "In progress"
        case .done:       return "Done"
        case .unknown:    return "Unknown"
        }
    }

    public var tint: ReadinessTint {
        switch self {
        case .toDo:       return .gray
        case .inProgress: return .blue
        case .done:       return .green
        case .unknown:    return .gray
        }
    }
}

public struct JiraIssue: Sendable, Equatable, Identifiable {
    public let key: String
    public let summary: String
    /// The site's own wording, shown as-is. Grouping goes by category.
    public let statusName: String
    public let statusCategory: JiraStatusCategory
    public let issueType: String
    public let updatedAt: Date

    public var id: String { key }

    public init(
        key: String,
        summary: String,
        statusName: String,
        statusCategory: JiraStatusCategory,
        issueType: String,
        updatedAt: Date
    ) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.statusCategory = statusCategory
        self.issueType = issueType
        self.updatedAt = updatedAt
    }
}
