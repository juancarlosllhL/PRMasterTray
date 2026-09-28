import SwiftUI
import PRMasterCore

/// Columns of a fixed height so they all reach the same bottom edge. Ragged
/// columns do not read as a board.
struct JiraBoardView: View {
    let columns: [JiraColumn]
    let jira: JiraStore
    let filter: PRFilter
    let onOpenIssue: (JiraIssue) -> Void
    let issueLink: (JiraIssue) -> URL?
    let onOpenLink: (LinkedPullRequest) -> Void

    @State private var targetedLane: JiraLane?
    @Environment(\.palette) private var palette

    private static let columnWidth = CGFloat(JiraBoard.columnWidth)
    private static let columnHeight = CGFloat(JiraBoard.columnHeight)

    var body: some View {
        HStack(alignment: .top, spacing: CGFloat(JiraBoard.gutter)) {
            ForEach(columns) { column in
                self.column(column)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, CGFloat(JiraBoard.outerPadding))
        .padding(.bottom, CGFloat(JiraBoard.outerPadding))
    }

    private static let cardsBeforeScrolling = 5
    /// An empty column is only a header tall, too small to aim a drop at.
    private static let minimumDropHeight: CGFloat = 160

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
        .frame(minHeight: Self.minimumDropHeight, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.wash(.blue))
                .opacity(targetedLane == column.lane ? 1 : 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.color(.blue).opacity(0.6), lineWidth: 1.5)
                .opacity(targetedLane == column.lane ? 1 : 0)
        }
        .modifier(DropTarget(lane: column.lane, jira: jira, targetedLane: $targetedLane))
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
                    isMoving: jira.isMoving(issue.key),
                    onToggle: { jira.toggle(issue.key) },
                    onOpenIssue: { onOpenIssue(issue) },
                    onOpenLink: onOpenLink
                )
                .modifier(DragSource(key: issue.key, isEnabled: jira.canMove && !jira.isMoving(issue.key)))
                .jiraIssueMenu(issue, jira: jira, link: issueLink(issue))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }
}
