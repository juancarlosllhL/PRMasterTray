import Foundation

/// Matched on a substring because sites rename their types freely, and support
/// is checked first so "Customer Support Ticket" is not read as something else.
public enum JiraIssueType {

    public static func tint(for name: String) -> ReadinessTint {
        let folded = name.trimmingCharacters(in: .whitespaces).lowercased()
        if folded.contains("support") { return .yellow }
        if folded.contains("bug") { return .red }
        if folded.contains("story") { return .green }
        if folded.contains("task") { return .blue }
        return .gray
    }

    /// Only support is shortened: it is the one name long enough to push the
    /// status and the pull request count off the end of a row.
    public static func shortName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().contains("support") ? "CST" : trimmed
    }
}

extension JiraIssue {
    public var typeTint: ReadinessTint { JiraIssueType.tint(for: issueType) }
    public var typeLabel: String { JiraIssueType.shortName(for: issueType) }
}
