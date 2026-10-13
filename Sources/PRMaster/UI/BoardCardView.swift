import SwiftUI
import PRMasterCore

/// The board's answer to `BoardRowView`: the same card stacked into a
/// column's width instead of spread across the popover's.
struct BoardCardView: View {
    let card: BoardCard
    let links: [LinkedPullRequest]
    let isExpanded: Bool
    var showsPriority = false
    var isMoving = false
    let onToggle: () -> Void
    let onOpen: () -> Void
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
                .strokeBorder(palette.color(card.tint).opacity(0.25))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        palette.wash(card.tint)
            .opacity(isHovering ? 1 : 0.55)
    }

    private var heading: some View {
        HStack(spacing: 5) {
            SourceMarks(sources: card.sources)
            Text(verbatim: card.reference)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.color(card.tint))
                .lineLimit(1)
                .truncationMode(.middle)
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
    /// truncates most titles to uselessness.
    private var summary: some View {
        Text(verbatim: card.title)
            .font(.rowTitle)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .truncationMode(.tail)
            .helpWhenTruncated(card.title)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if showsPriority, let symbol = card.priority.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.color(card.priority.tint))
                    .help("\(card.priority.name) priority")
                    .accessibilityLabel("\(card.priority.name) priority")
            }
            chip(card.typeLabel, tint: card.typeTint)
            if isMoving {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
                    .accessibilityLabel("Moving")
            }
            Text(verbatim: card.statusName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let linkState = card.linkState {
                linkControl(linkState)
            }
        }
    }

    /// A button only where there is something to expand, so a card with no pull
    /// requests does not offer a control that would do nothing.
    @ViewBuilder
    private func linkControl(_ linkState: IssueLinkState) -> some View {
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
                Text(verbatim: JiraBoard.cardLinkSummary(linkState, count: links.count))
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
        card.createdAt.map { RelativeAge.label(since: $0, now: Date()) }
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
