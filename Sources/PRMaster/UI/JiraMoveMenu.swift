import AppKit
import SwiftUI
import PRMasterCore

/// One menu per issue: SwiftUI shows only one of two stacked context menus.
/// The moves repeat what dragging does, for the list and for VoiceOver.
struct JiraIssueMenu: ViewModifier {
    let issue: JiraIssue
    let jira: JiraStore
    let link: URL?

    func body(content: Content) -> some View {
        content.contextMenu {
            CopyMenuItems(link: link, id: issue.key)
            if jira.canMove {
                Divider()
                ForEach(JiraLane.allCases.filter { $0 != jira.lane(of: issue) }, id: \.self) { lane in
                    Button("Move to \(lane.title)", systemImage: "arrow.right") {
                        Task { await jira.move(issue.key, to: lane) }
                    }
                    .disabled(jira.isMoving(issue.key))
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
    func jiraIssueMenu(_ issue: JiraIssue, jira: JiraStore, link: URL?) -> some View {
        modifier(JiraIssueMenu(issue: issue, jira: jira, link: link))
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

/// The payload is the bare key. A string dropped from another app is ignored by `move`.
struct DragSource: ViewModifier {
    let key: String
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(key)
        } else {
            content
        }
    }
}

struct DropTarget: ViewModifier {
    let lane: JiraLane
    let jira: JiraStore
    @Binding var targetedLane: JiraLane?

    func body(content: Content) -> some View {
        if jira.canMove {
            content.dropDestination(for: String.self) { keys, _ in
                guard let key = keys.first,
                      let issue = jira.issues.first(where: { $0.key == key }),
                      jira.lane(of: issue) != lane
                else { return false }
                Task { await jira.move(key, to: lane) }
                return true
            } isTargeted: { isTargeted in
                if isTargeted {
                    targetedLane = lane
                } else if targetedLane == lane {
                    targetedLane = nil
                }
            }
        } else {
            content
        }
    }
}
