import AppKit
import SwiftUI
import PRMasterCore

/// The popover's list in a panel the full height of the screen, pinned to one
/// side and left open.
///
/// Borderless, so the header sits where the traffic lights would, and not
/// movable: its whole point is to stay where it was put. It follows the visible
/// frame — menu bar and Dock excluded — whenever the screens change.
@MainActor
final class DockedPanelController {

    private var panel: DockedPanel?
    private var hosting: NSView?
    private var placement: PanelPlacement = .popover
    private var width: CGFloat?
    private var screen: () -> NSScreen? = { NSScreen.main }
    private var screenObserver: NSObjectProtocol?

    var window: NSWindow? { panel }
    /// Where the panel sits and the visible frame of its screen, or nil once it
    /// is hidden — what anything keeping clear of it needs to know.
    var onLayout: (((panel: NSRect, screen: NSRect)?) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    /// Builds the panel the first time; after that only re-pins it, so switching
    /// sides does not throw the list's scroll position away.
    func dock<Content: View>(
        _ placement: PanelPlacement,
        on screen: @escaping () -> NSScreen?,
        content: () -> Content
    ) {
        self.placement = placement
        self.screen = screen
        if panel == nil {
            let hosting = FirstClickHostingView(rootView: content())
            // The window is sized from `setWidth`, never from the view: letting the
            // hosting view's intrinsic size constrain it would fight the pinning.
            hosting.sizingOptions = []
            panel = makePanel(around: hosting)
            self.hosting = hosting
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.pin() }
            }
        }
        // Regardless: at launch an accessory app is not active, and a plain
        // `orderFront` would leave the panel behind whatever is.
        panel?.orderFrontRegardless()
        pin()
    }

    /// Back to the popover. Torn down rather than hidden, so nothing keeps
    /// rendering a list nobody can see.
    func undock() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.orderOut(nil)
        onLayout?(nil)
        panel?.contentView = nil
        panel = nil
        hosting = nil
        width = nil
        placement = .popover
    }

    func show() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        pin()
    }

    func hide() {
        panel?.orderOut(nil)
        onLayout?(nil)
    }

    /// The width the list asked for. The board tab is wider than the pull
    /// requests, so this changes with the tab and the panel follows.
    func setWidth(_ width: CGFloat) {
        guard width > 0, width != self.width else { return }
        self.width = width
        pin()
    }

    private func pin() {
        guard let panel, let visible = (screen() ?? NSScreen.main)?.visibleFrame else { return }
        let width = width ?? hosting?.fittingSize.width ?? 440
        guard let frame = placement.frame(width: Double(width), in: visible) else { return }
        panel.setFrame(frame, display: true)
        if panel.isVisible { onLayout?((frame, visible)) }
    }

    private func makePanel(around hosting: NSView) -> DockedPanel {
        let panel = DockedPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isMovable = false
        // Above other apps' windows: at the normal level the first maximised
        // window to come forward would bury it, which defeats leaving it open.
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // On every desktop, so switching Spaces does not leave it behind, and out
        // of the way of a full-screen app rather than crowding it.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "PR Master Tray"

        // The popover's own material, so liquid glass looks the same in both.
        // Opaque draws `windowBackgroundColor` over it from the SwiftUI side.
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        hosting.frame = material.bounds
        hosting.autoresizingMask = [.width, .height]
        material.addSubview(hosting)
        panel.contentView = material
        return panel
    }
}

/// A borderless window refuses key status unless told otherwise, and without it
/// the board's filter field could not be typed into.
private final class DockedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel sits beside other apps' windows, so its first click has to land on
/// the row it was aimed at rather than only bring the app forward.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
