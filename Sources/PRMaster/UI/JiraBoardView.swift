import SwiftUI
import PRMasterCore

/// Columns of a fixed height so they all reach the same bottom edge. Ragged
/// columns do not read as a board.
struct JiraBoardView: View {
    let columns: [JiraColumn]
    let jira: JiraStore
    let filter: PRFilter
    let onOpenIssue: (JiraIssue) -> Void
    let onOpenLink: (LinkedPullRequest) -> Void

    private static let columnWidth = CGFloat(JiraBoard.columnWidth)
    private static let columnHeight = CGFloat(JiraBoard.columnHeight)

    var body: some View {
        HStack(alignment: .top, spacing: CGFloat(JiraBoard.gutter)) {
            ForEach(columns) { column in
                self.column(column)
            }
        }
        .padding(.horizontal, CGFloat(JiraBoard.outerPadding))
        .padding(.bottom, CGFloat(JiraBoard.outerPadding))
    }

    private static let cardsBeforeScrolling = 5

    /// Only the long columns get a scroller and a fixed height. A short one
    /// sized to the tallest would leave the popover mostly empty space.
    @ViewBuilder
    private func column(_ column: JiraColumn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeaderView(title: column.title, trailing: "\(column.issues.count)")
            if column.issues.isEmpty {
                empty
            } else if column.issues.count > Self.cardsBeforeScrolling {
                ScrollView { cards(column) }
                    .frame(height: Self.columnHeight)
            } else {
                cards(column)
            }
        }
        .frame(width: Self.columnWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.title), \(column.issues.count) issues")
    }

    /// Kept rather than collapsed: an empty column is what says the group exists
    /// and has nothing in it.
    private var empty: some View {
        Text("Nothing here")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private func cards(_ column: JiraColumn) -> some View {
        LazyVStack(spacing: 6) {
            ForEach(column.issues) { issue in
                JiraIssueCardView(
                    issue: issue,
                    links: jira.links(for: issue.key, under: filter),
                    linkState: jira.linkState(for: issue.key),
                    isExpanded: jira.expandedKeys.contains(issue.key),
                    showsPriority: column.showsPriority,
                    onToggle: { jira.toggle(issue.key) },
                    onOpenIssue: { onOpenIssue(issue) },
                    onOpenLink: onOpenLink
                )
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }
}
