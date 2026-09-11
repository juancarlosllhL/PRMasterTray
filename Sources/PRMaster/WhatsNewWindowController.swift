import AppKit
import SwiftUI
import PRMasterCore

/// Owns the window that says what the last update changed.
///
/// An `NSPanel` for the same reason as the settings window: this app has no menu
/// bar of its own, and a panel closes on Escape without one.
@MainActor
final class WhatsNewWindowController {

    private var panel: NSPanel?
    private var onClose: (() -> Void)?

    func show(entries: [ChangelogEntry], onSeen: @escaping () -> Void) {
        guard !entries.isEmpty, panel == nil else { return }
        onClose = onSeen

        let hosting = NSHostingController(
            rootView: WhatsNewView(entries: entries) { [weak self] in self?.close() }
        )
        hosting.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(contentViewController: hosting)
        panel.title = "What's new"
        panel.styleMask = [.titled, .closable]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.center()
        // Closing by the title bar button counts as read, exactly like Continue.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.markSeen() }
        }

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.close()
    }

    private func markSeen() {
        onClose?()
        onClose = nil
    }
}
