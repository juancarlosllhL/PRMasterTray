import AppKit
import SwiftUI
import PRMasterCore

/// One menu per card: SwiftUI shows only one of two stacked context menus.
/// The moves repeat what dragging does, for the list and for VoiceOver.
struct BoardCardMenu: ViewModifier {
    let card: BoardCard
    let board: BoardStore
    let link: URL?

    func body(content: Content) -> some View {
        content.contextMenu {
            CopyMenuItems(link: link, id: card.copyID)
            if board.canMove(card) {
                Divider()
                ForEach(BoardLane.allCases.filter { $0 != card.lane }, id: \.self) { lane in
                    Button("Move to \(lane.title)", systemImage: "arrow.right") {
                        Task { await board.move(card.id, to: lane) }
                    }
                    .disabled(board.isMoving(card.id))
                }
            }
        }
    }
}

struct CopyMenuItems: View {
    let link: URL?
    let id: String

    var body: some View {
        if let link {
            Button("Copy Link", systemImage: "link") { Self.copy(link.absoluteString) }
        }
        Button("Copy ID", systemImage: "number") { Self.copy(id) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension View {
    func boardCardMenu(_ card: BoardCard, board: BoardStore, link: URL?) -> some View {
        modifier(BoardCardMenu(card: card, board: board, link: link))
    }

    func copyMenu(link: URL, repo: String, number: Int, jira: JiraKeyReference? = nil) -> some View {
        contextMenu {
            CopyMenuItems(link: link, id: PullRequestReference.id(repo: repo, number: number))
            if let jira {
                Divider()
                JiraKeyMenuItems(reference: jira)
            }
        }
    }
}

/// `link` is nil while signed out of Jira: the key is still worth copying.
struct JiraKeyReference {
    let key: String
    let link: URL?
    let open: (URL) -> Void
}

struct JiraKeyMenuItems: View {
    let reference: JiraKeyReference

    var body: some View {
        Button("Copy Jira ID", systemImage: "ticket") { CopyMenuItems.copy(reference.key) }
        if let link = reference.link {
            Button("Copy Jira Link", systemImage: "link") { CopyMenuItems.copy(link.absoluteString) }
            Button("Open \(reference.key) in Jira", systemImage: "arrow.up.right.square") { reference.open(link) }
        }
    }
}

/// The payload is a `BoardCardID`. A string dropped from another app names no card.
struct DragSource: ViewModifier {
    let id: BoardCardID
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(id.rawValue)
        } else {
            content
        }
    }
}

struct DropTarget: ViewModifier {
    let lane: BoardLane
    let board: BoardStore
    @Binding var targetedLane: BoardLane?

    func body(content: Content) -> some View {
        content.dropDestination(for: String.self) { payloads, _ in
            guard let id = payloads.first.flatMap(BoardCardID.init(rawValue:)),
                  let card = board.card(id), board.canMove(card), card.lane != lane
            else { return false }
            Task { await board.move(id, to: lane) }
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                targetedLane = lane
            } else if targetedLane == lane {
                targetedLane = nil
            }
        }
    }
}
