import AppKit
import SwiftUI
import PRMasterCore

/// Owns one diff window per pull request.
///
/// An `NSPanel`, like the settings window: this app has no menu bar of its own,
/// so a panel's Escape is the only close key a user will find.
@MainActor
final class DiffWindowController: NSObject, NSWindowDelegate {

    private let registry = WindowRegistry<NSPanel>()

    func show(
        _ subject: DiffSubject,
        source: PullRequestDiffing?,
        viewedWriter: PullRequestDiffing?,
        appearance: AppearanceStore,
        live: @escaping () -> DiffLiveState,
        onAct: @escaping (MergeTarget, _ close: @escaping () -> Void) -> Void,
        onOpen: @escaping (URL) -> Void
    ) {
        let (panel, _) = registry.window(for: subject.id) {
            makePanel(subject, source: source, viewedWriter: viewedWriter, appearance: appearance,
                      live: live, onAct: onAct, onOpen: onOpen)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel(
        _ subject: DiffSubject,
        source: PullRequestDiffing?,
        viewedWriter: PullRequestDiffing?,
        appearance: AppearanceStore,
        live: @escaping () -> DiffLiveState,
        onAct: @escaping (MergeTarget, @escaping () -> Void) -> Void,
        onOpen: @escaping (URL) -> Void
    ) -> NSPanel {
        weak var weakPanel: NSPanel?
        let store = DiffStore(repo: subject.repo, number: subject.number, source: source, viewedWriter: viewedWriter)
        let hosting = NSHostingController(rootView: DiffWindowView(
            store: store,
            subject: subject,
            live: live,
            appearance: appearance,
            onAct: { target in onAct(target) { weakPanel?.close() } },
            onOpenOnGitHub: { onOpen(subject.url) }
        ))
        hosting.sizingOptions = []

        let panel = NSPanel(contentViewController: hosting)
        weakPanel = panel
        panel.title = "\(subject.repo) #\(subject.number) · \(subject.title)"
        panel.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setContentSize(NSSize(width: 1180, height: 760))
        panel.contentMinSize = NSSize(width: 760, height: 420)
        panel.center()

        panel.identifier = NSUserInterfaceItemIdentifier(subject.id)
        panel.delegate = self
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        guard let key = (notification.object as? NSWindow)?.identifier?.rawValue else { return }
        registry.remove(key)
    }
}
