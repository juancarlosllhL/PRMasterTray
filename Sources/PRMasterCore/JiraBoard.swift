import Foundation

public enum JiraBoard {
    public static let listWidth: Double = 380
    public static let columnWidth: Double = 230
    public static let gutter: Double = 8
    public static let outerPadding: Double = 10
    public static let columnHeight: Double = 380

    /// A popover measured wider than its display is repositioned rather than
    /// shrunk, so this leaves room for its own shadow and arrow.
    public static let screenMargin: Double = 40

    public static func width(columns: Int, available: Double) -> Double {
        guard columns > 0 else { return listWidth }
        let wanted = Double(columns) * columnWidth
            + Double(columns - 1) * gutter
            + 2 * outerPadding
        return max(listWidth, min(wanted, available - screenMargin))
    }

    /// The popover is only ever wide for a board that is actually on screen, so
    /// the tab and the flag are decided here rather than in the view.
    public static func popoverWidth(
        isJiraTab: Bool,
        showsBoard: Bool,
        columns: Int,
        available: Double
    ) -> Double {
        guard isJiraTab, showsBoard else { return listWidth }
        return width(columns: columns, available: available)
    }

    public static func layoutSummary(_ layout: JiraLayout, columns: Int) -> String {
        guard layout == .board else {
            return "One section under another, in the width the popover has always had."
        }
        return "A column per group. The popover widens to fit \(columns) of them "
            + "while the Jira tab is open, and narrows again when it is not."
    }

    /// Shorter than the row's wording: a card is a column wide, not a popover.
    public static func cardLinkSummary(_ state: IssueLinkState, count: Int) -> String {
        switch state {
        case .loading: return "Checking…"
        case .unknown: return "Couldn't check"
        case .none:    return "No PRs"
        case .linked:  return count == 1 ? "1 pull request" : "\(count) pull requests"
        }
    }
}

public struct JiraColumn: Sendable, Equatable, Identifiable {
    public let title: String
    public let issues: [JiraIssue]
    public let showsPriority: Bool

    public var id: String { title }

    public init(title: String, issues: [JiraIssue], showsPriority: Bool) {
        self.title = title
        self.issues = issues
        self.showsPriority = showsPriority
    }
}

extension JiraGroups {

    /// Left to right in the order the work moves, which is not the order the list
    /// stacks them in. Empty columns are kept, unlike the list's sections; Done is
    /// the exception, dropped when its window is off because it can never fill.
    public func boardColumns(includesDone: Bool) -> [JiraColumn] {
        var columns = [
            JiraColumn(title: "To do", issues: toDo, showsPriority: true),
            JiraColumn(title: "In progress", issues: inProgress, showsPriority: true),
            JiraColumn(title: "Testing", issues: testing, showsPriority: true),
        ]
        if includesDone {
            columns.append(JiraColumn(title: "Done", issues: done, showsPriority: false))
        }
        return columns
    }
}
