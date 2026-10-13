import SwiftUI
import PRMasterCore

/// Columns of a fixed height so they all reach the same bottom edge. Ragged
/// columns do not read as a board.
struct BoardView: View {
    let columns: [BoardColumn]
    let board: BoardStore
    let filter: PRFilter
    let onOpenCard: (BoardCard) -> Void
    let cardLink: (BoardCard) -> URL?
    let onOpenLink: (LinkedPullRequest) -> Void

    @State private var targetedLane: BoardLane?
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
    private func column(_ column: BoardColumn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeaderView(title: column.title, trailing: "\(column.cards.count)")
            if column.cards.isEmpty {
                empty
            } else if column.cards.count > Self.cardsBeforeScrolling {
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
        .modifier(DropTarget(lane: column.lane, board: board, targetedLane: $targetedLane))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.title), \(column.cards.count) cards")
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

    private func cards(_ column: BoardColumn) -> some View {
        LazyVStack(spacing: 6) {
            ForEach(column.cards) { card in
                BoardCardView(
                    card: card,
                    links: filter.apply(to: card.links),
                    isExpanded: board.isExpanded(card.id),
                    showsPriority: column.showsPriority,
                    isMoving: board.isMoving(card.id),
                    onToggle: { board.toggle(card.id) },
                    onOpen: { onOpenCard(card) },
                    onOpenLink: onOpenLink
                )
                .modifier(DragSource(id: card.id, isEnabled: board.canMove(card) && !board.isMoving(card.id)))
                .boardCardMenu(card, board: board, link: cardLink(card))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }
}
