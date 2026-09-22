import SwiftUI
import PRMasterCore

/// The board's answer to `JiraIssueRowView`: the same issue stacked into a
/// column's width instead of spread across the popover's.
struct JiraIssueCardView: View {
    let issue: JiraIssue
    let links: [LinkedPullRequest]
    let linkState: IssueLinkState
    let isExpanded: Bool
    var showsPriority = false
    let onToggle: () -> Void
    let onOpenIssue: () -> Void
    let onOpenLink: (LinkedPullRequest) -> Void

    @State private var isHovering = false
    @Environment(\.palette) private var palette

    private static let nestedRowsBeforeScrolling = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            heading
            summary
            footer
            if isExpanded { nested }
        }
        .padding(8)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(palette.color(issue.statusCategory.tint).opacity(0.25))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenIssue)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        palette.wash(issue.statusCategory.tint)
            .opacity(isHovering ? 1 : 0.55)
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Text(verbatim: issue.key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.color(issue.statusCategory.tint))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let age {
                Text(verbatim: age)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    /// Two lines rather than one: a column is narrow enough that a single line
    /// truncates most summaries to uselessness.
    private var summary: some View {
        Text(verbatim: issue.summary)
            .font(.rowTitle)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .truncationMode(.tail)
            .helpWhenTruncated(issue.summary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if showsPriority, let symbol = issue.priority.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.color(issue.priority.tint))
                    .help("\(issue.priority.name) priority")
                    .accessibilityLabel("\(issue.priority.name) priority")
            }
            chip(issue.typeLabel, tint: issue.typeTint)
            Text(verbatim: issue.statusName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            linkControl
        }
    }

    /// A button only where there is something to expand, so a card with no pull
    /// requests does not offer a control that would do nothing.
    @ViewBuilder
    private var linkControl: some View {
        if linkState == .linked {
            Button(action: onToggle) {
                HStack(spacing: 3) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(verbatim: "\(links.count)")
                        .font(.system(size: 10, design: .monospaced))
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse pull requests" : "Expand pull requests")
        } else {
            HStack(spacing: 3) {
                if linkState == .loading {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                }
                Text(verbatim: linkSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func chip(_ text: String, tint: ReadinessTint) -> some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: palette.isMonochrome ? .semibold : .medium))
            .foregroundStyle(palette.color(tint))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(palette.wash(tint))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .lineLimit(1)
            .fixedSize()
    }

    private var age: String? {
        issue.createdAt.map { RelativeAge.label(since: $0, now: Date()) }
    }

    private var linkSummary: String {
        JiraBoard.cardLinkSummary(linkState, count: links.count)
    }

    @ViewBuilder
    private var nested: some View {
        if links.count > Self.nestedRowsBeforeScrolling {
            ScrollView { nestedRows }
                .frame(height: 96)
        } else {
            nestedRows
        }
    }

    private var nestedRows: some View {
        VStack(spacing: 2) {
            ForEach(links) { pr in
                LinkedPullRequestRowView(pull: pr) { onOpenLink(pr) }
            }
        }
    }
}
