import SwiftUI
import PRMasterCore

/// The first expandable row in this app, so the chevron is drawn by hand rather
/// than with `DisclosureGroup`, whose own indent and animation do not line up
/// with the flat rows in the other tab.
struct JiraIssueRowView: View {
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

    private static let nestedRowsBeforeScrolling = 4

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded { nested }
        }
    }

    /// The whole left gutter at full row height, not the glyph alone: missing
    /// an 18pt chevron opened the issue in a browser instead.
    private var toggle: some View {
        Button(action: onToggle) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.gutterWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(linkState != .linked)
        .opacity(linkState == .linked ? 1 : 0)
        .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
    }

    private static let gutterWidth: CGFloat = 34

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            toggle

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: issue.key)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.color(issue.statusCategory.tint))
                    Text(verbatim: issue.summary)
                        .font(.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .helpWhenTruncated(issue.summary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    if showsPriority, let symbol = issue.priority.symbolName {
                        Image(systemName: symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.color(issue.priority.tint))
                            .frame(width: 10)
                            .help("\(issue.priority.name) priority")
                            .accessibilityLabel("\(issue.priority.name) priority")
                    }
                    chip(issue.typeLabel, tint: issue.typeTint)
                    Text(verbatim: issue.statusName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(verbatim: "·")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if linkState == .loading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                            .frame(width: 10, height: 10)
                    }
                    Text(verbatim: linkSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let age {
                        Text(verbatim: age)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }
            .padding(.vertical, 7)
        }
        .padding(.trailing, 12)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenIssue)
        .onHover { isHovering = $0 }
    }

    private func chip(_ text: String, tint: ReadinessTint) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: palette.isMonochrome ? .semibold : .medium))
            .foregroundStyle(palette.color(tint))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(palette.wash(tint))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .lineLimit(1)
            .fixedSize()
    }

    private var age: String? {
        issue.createdAt.map { RelativeAge.label(since: $0, now: Date()) }
    }

    /// The search is scoped to the viewer, so a colleague's pull request is
    /// invisible here and this counts only your own.
    private var linkSummary: String {
        switch linkState {
        case .loading:
            return "Checking pull requests…"
        case .unknown:
            return "Couldn't check for pull requests"
        case .none:
            return "No PRs open"
        case .linked:
            return links.count == 1
                ? "1 pull request"
                : "\(links.count) pull requests"
        }
    }

    @ViewBuilder
    private var nested: some View {
        if links.count > Self.nestedRowsBeforeScrolling {
            ScrollView { nestedRows }
                .frame(height: 132)
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
        .padding(.leading, Self.gutterWidth + 6)
        .padding(.trailing, 4)
        .padding(.bottom, 4)
    }
}

struct LinkedPullRequestRowView: View {
    let pull: LinkedPullRequest
    let onOpen: () -> Void

    @State private var isHovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(palette.color(pull.state.tint))
                .frame(width: 14)
                .accessibilityLabel(pull.state.label)

            Text(verbatim: pull.repo)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.head)
                .helpWhenTruncated(pull.repo, font: .system(size: 11))

            Text(verbatim: "#\(pull.number)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text(verbatim: pull.isDraft ? "draft" : pull.state.label)
                .font(.system(size: 10, weight: palette.isMonochrome ? .semibold : .regular))
                .foregroundStyle(palette.color(pull.state.tint))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
    }

    private var symbol: String {
        switch pull.state {
        case .open:   return pull.isDraft ? "circle.dashed" : "arrow.triangle.pull"
        case .merged: return "checkmark.circle.fill"
        case .closed: return "xmark.circle"
        }
    }
}
