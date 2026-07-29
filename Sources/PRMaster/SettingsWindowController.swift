import AppKit
import SwiftUI
import PRMasterCore

/// Owns the settings window.
///
/// An `NSPanel`, not an `NSWindow`: this app is an `LSUIElement`, so it has no
/// menu bar of its own — no Cmd-W, no Cmd-comma, no Window menu. A panel closes
/// on Escape without any of that, which is otherwise the one keystroke a user
/// will reach for and not find.
///
/// The panel is built once and kept, so reopening it lands where the user left
/// it rather than jumping back to the centre of the screen.
@MainActor
final class SettingsWindowController {

    private var panel: NSPanel?

    func show(store: PRStore) {
        if let panel {
            present(panel)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(store: store))
        // Without this the panel is sized once from a stale measurement, which
        // for a form whose organization list arrives with the first fetch means
        // a window sized for an empty list. Same fix as the popover.
        hosting.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(contentViewController: hosting)
        panel.title = "PR Master Tray Settings"
        // Not resizable: the content is a fixed-width form that scrolls.
        panel.styleMask = [.titled, .closable]
        // Dropping the style leaves the buttons behind as greyed-out stubs, and
        // three dots where one belongs reads as a window that lost something.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Closing must not deallocate it — the reference here is what makes
        // reopening cheap, and releasing a window ARC still owns is a crash.
        panel.isReleasedWhenClosed = false
        // A settings window that vanishes when you switch to the browser to
        // check an organization name would be useless.
        panel.hidesOnDeactivate = false
        panel.center()

        self.panel = panel
        present(panel)
    }

    /// An accessory app is not active when its menu bar item is clicked, so
    /// without activating first the panel opens behind whatever the user was
    /// looking at and takes no keyboard input.
    private func present(_ panel: NSPanel) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
