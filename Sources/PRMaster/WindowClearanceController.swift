import AppKit
import ApplicationServices
import PRMasterCore

/// Moves other apps' windows off the side panel.
///
/// macOS has no way for an app to reserve part of the screen — the visible
/// frame only ever leaves out the menu bar and the Dock — so this does what a
/// window manager does: watches every regular app's windows through the
/// Accessibility API and pushes any that land on the panel back beside it.
///
/// Needs the Accessibility permission, which is why it only runs once the user
/// has switched it on in Settings.
@MainActor
@Observable
final class WindowClearanceController {

    /// Read live: the permission is granted in System Settings, behind the app's back.
    private(set) var isTrusted = AXIsProcessTrusted()

    /// Each panel and its screen's visible frame, in AppKit's bottom-left space.
    @ObservationIgnored private var layouts: [(panel: NSRect, screen: NSRect)] = []
    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var sweep: Task<Void, Never>?
    @ObservationIgnored private var trustPoll: Task<Void, Never>?
    /// What a window settled at after being asked to move and refusing — some
    /// apps keep a minimum width wider than the room beside the panel. Left
    /// alone while it stays there, or every notification would ask again.
    @ObservationIgnored private var refused: [CFHashCode: CGRect] = [:]

    /// Starts keeping windows clear of every panel in `layouts`, or stops when
    /// there is none.
    func enforce(_ layouts: [(panel: NSRect, screen: NSRect)]) {
        self.layouts = layouts
        guard !layouts.isEmpty else { return stop() }
        refreshTrust()
        guard isTrusted else { return pollForTrust() }
        if workspaceObservers.isEmpty { start() }
        scheduleSweep(after: .zero)
    }

    /// Shows the system's own prompt, which offers to open System Settings.
    func requestTrust() {
        // The constant's own value, spelled out: the imported global is mutable
        // C state that strict concurrency will not let this read.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        if !isTrusted { pollForTrust() }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!)
    }

    func refreshTrust() {
        isTrusted = AXIsProcessTrusted()
    }

    // MARK: - Observing

    private func start() {
        for app in NSWorkspace.shared.runningApplications { observe(app) }

        let center = NSWorkspace.shared.notificationCenter
        let launched = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self, let app else { return }
                self.observe(app)
                self.scheduleSweep()
            }
        }
        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, let pid, let observer = self.observers.removeValue(forKey: pid) else { return }
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        // A window can arrive on this desktop without moving at all.
        let sweepers = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleSweep() }
            }
        }
        workspaceObservers = [launched, terminated] + sweepers
    }

    private func stop() {
        sweep?.cancel()
        sweep = nil
        trustPoll?.cancel()
        trustPoll = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        refused.removeAll()
    }

    /// Regular apps only: an accessory app's windows are palettes and HUDs that
    /// were placed on purpose, and moving them would be a bug in somebody else's app.
    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular,
              pid != ProcessInfo.processInfo.processIdentifier,
              observers[pid] == nil
        else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [
            kAXWindowCreatedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification,
        ] {
            AXObserverAddNotification(observer, element, notification as CFString, refcon)
        }
        // Common modes, so a window dragged during another app's menu tracking still counts.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    /// Delivered on the main run loop, where the source was added.
    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let controller = Unmanaged<WindowClearanceController>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { controller.scheduleSweep() }
    }

    private func pollForTrust() {
        guard trustPoll == nil else { return }
        trustPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                refreshTrust()
                if isTrusted {
                    trustPoll = nil
                    enforce(layouts)
                    return
                }
            }
        }
    }

    // MARK: - Sweeping

    /// Coalesced: one drag sends dozens of moves, and every window is checked anyway.
    private func scheduleSweep(after delay: Duration = .milliseconds(150)) {
        sweep?.cancel()
        sweep = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Pushing a window the user is still dragging fights the mouse.
            // It is checked again once the button comes up.
            if NSEvent.pressedMouseButtons != 0 {
                return scheduleSweep(after: .milliseconds(300))
            }
            clearWindows()
        }
    }

    private func clearWindows() {
        guard !layouts.isEmpty, isTrusted, let primary = NSScreen.screens.first?.frame else { return }
        let regions = layouts.map {
            (panel: Self.topLeft($0.panel, primary: primary), screen: Self.topLeft($0.screen, primary: primary))
        }

        for pid in observers.keys {
            let app = AXUIElementCreateApplication(pid)
            for window in Self.windows(of: app) {
                guard Self.isMovable(window), let frame = Self.frame(of: window) else { continue }
                let key = CFHash(window)
                if refused[key] == frame { continue }
                // A window only ever sits on one panel's screen, so the first
                // panel it overlaps is the one to clear.
                guard let (target, region) = regions.lazy.compactMap({ region in
                    WindowClearance.clearedFrame(frame, avoiding: region.panel, within: region.screen)
                        .map { ($0, region) }
                }).first else {
                    refused[key] = nil
                    continue
                }
                Self.setFrame(target, of: window)
                if let settled = Self.frame(of: window),
                   WindowClearance.clearedFrame(settled, avoiding: region.panel, within: region.screen) != nil {
                    refused[key] = settled
                }
            }
        }
    }

    // MARK: - Accessibility

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// Ordinary document windows only: not dialogs, sheets or floating panels,
    /// and not one minimised or in full screen, which has a desktop of its own.
    private static func isMovable(_ window: AXUIElement) -> Bool {
        guard string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return false }
        if bool(window, kAXMinimizedAttribute) == true { return false }
        if bool(window, "AXFullScreen") == true { return false }
        return true
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = value(window, kAXPositionAttribute),
              let sizeValue = value(window, kAXSizeAttribute),
              AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Size, position, then size again: the first resize can be clamped by the
    /// screen edge the window has not yet moved away from.
    private static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    /// AppKit counts up from the primary screen's bottom edge; Accessibility
    /// counts down from its top.
    private static func topLeft(_ rect: NSRect, primary: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
