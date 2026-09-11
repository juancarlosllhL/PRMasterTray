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

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(linkState != .linked)
            .opacity(linkState == .linked ? 1 : 0)
            .accessibilityLabel(isExpanded ? "Collapse" : "Expand")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: issue.key)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.color(issue.statusCategory.tint))
                    Text(verbatim: issue.summary)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    Text(verbatim: issue.statusName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(verbatim: "·")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(verbatim: linkSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenIssue)
        .onHover { isHovering = $0 }
    }

    /// "No pull request of yours yet" rather than "none": the search is scoped
    /// to the viewer, so a colleague's pull request is invisible here and the
    /// stronger claim would be false.
    private var linkSummary: String {
        switch linkState {
        case .unknown:
            return "Couldn't check for pull requests"
        case .none:
            return "No pull request of yours yet"
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
        .padding(.leading, 28)
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
