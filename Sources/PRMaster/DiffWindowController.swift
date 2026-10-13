import AppKit
import SwiftUI
import PRMasterCore

/// Owns one diff window per pull request, and keeps the app in the Dock while any is open.
@MainActor
final class DiffWindowController: NSObject, NSWindowDelegate {

    private let registry = WindowRegistry<DiffWindow>()
    private var keyMonitors: [String: Any] = [:]
    private let highlighter = BundledHighlighter()

    func show(
        _ subject: DiffSubject,
        source: PullRequestDiffing?,
        viewedWriter: PullRequestDiffing?,
        appearance: AppearanceStore,
        scorer: BlockScoring?,
        live: @escaping () -> DiffLiveState,
        onAct: @escaping (MergeTarget, _ close: @escaping () -> Void) -> Void,
        onOpen: @escaping (URL) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        let (window, isNew) = registry.window(for: subject.id) {
            makeWindow(subject, source: source, viewedWriter: viewedWriter, appearance: appearance, scorer: scorer,
                       live: live, onAct: onAct, onOpen: onOpen, onOpenSettings: onOpenSettings)
        }
        // Before activating, or the menu bar stays with the app the user came from.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // AppKit hands a new key window's first text field the focus, which here is the file filter.
        if isNew { DispatchQueue.main.async { window.makeFirstResponder(nil) } }
    }

    private func makeWindow(
        _ subject: DiffSubject,
        source: PullRequestDiffing?,
        viewedWriter: PullRequestDiffing?,
        appearance: AppearanceStore,
        scorer: BlockScoring?,
        live: @escaping () -> DiffLiveState,
        onAct: @escaping (MergeTarget, @escaping () -> Void) -> Void,
        onOpen: @escaping (URL) -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> DiffWindow {
        weak var weakWindow: DiffWindow?
        let store = DiffStore(repo: subject.repo, number: subject.number, source: source,
                              viewedWriter: viewedWriter, highlighter: highlighter, scorer: scorer)
        let hosting = NSHostingController(rootView: DiffWindowView(
            store: store,
            subject: subject,
            live: live,
            appearance: appearance,
            onOpenOnGitHub: { onOpen(subject.url) },
            onOpenSettings: onOpenSettings,
            initialFile: Debug.openFile
        ))
        hosting.sizingOptions = []
        weak var weakActions: NSView?
        let actions = NSHostingView(rootView: DiffTitleActions(
            store: store,
            subject: subject,
            live: live,
            onAct: { target in onAct(target) { weakWindow?.close() } },
            onOpenOnGitHub: { onOpen(subject.url) },
            onResize: { weakActions.map { $0.frame.size.width = $0.fittingSize.width } }
        ))
        weakActions = actions
        actions.frame.size = actions.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = actions
        accessory.layoutAttribute = .trailing

        let window = DiffWindow(contentViewController: hosting)
        weakWindow = window
        window.title = "\(subject.repo) #\(subject.number) · \(subject.title)"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.addTitlebarAccessoryViewController(accessory)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1360, height: 760))
        window.contentMinSize = NSSize(width: 760, height: 420)
        window.center()

        window.identifier = NSUserInterfaceItemIdentifier(subject.id)
        window.delegate = self
        // A text field's field editor takes Control-F as "move forward" before
        // any SwiftUI shortcut sees it, so the window listens first.
        keyMonitors[subject.id] = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === weakWindow,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
                  event.charactersIgnoringModifiers?.lowercased() == "f" else { return event }
            store.openFind()
            return nil
        }
        return window
    }

    func snapshotFrontWindow(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.delegate === self && $0.isVisible }) else { return }
        Debug.snapshot(window, to: url)
    }

    func windowWillClose(_ notification: Notification) {
        guard let key = (notification.object as? NSWindow)?.identifier?.rawValue else { return }
        registry.remove(key)
        keyMonitors.removeValue(forKey: key).map(NSEvent.removeMonitor)
        if registry.count == 0, !NSApp.setActivationPolicy(.accessory) {
            NSLog("PRMaster: the app could not leave the Dock after the last review closed")
        }
    }
}

/// Closes on Escape like the panel it replaced, which hid from the Dock and the app switchers.
private final class DiffWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Shiki from the app bundle, loaded on first use so the script's parse stays off the main thread.
private actor BundledHighlighter: SyntaxHighlighting {
    private var loaded: ShikiHighlighter??

    func highlight(_ file: DiffFile, theme: SyntaxTheme) async -> DiffFile {
        guard let highlighter = load() else { return file }
        return await highlighter.highlight(file, theme: theme)
    }

    private func load() -> ShikiHighlighter? {
        if let loaded { return loaded }
        do {
            guard let url = Bundle.main.url(forResource: "shiki", withExtension: "js") else {
                throw ShikiHighlighter.LoadError.missingEntryPoint
            }
            loaded = .some(try ShikiHighlighter(script: String(contentsOf: url, encoding: .utf8)))
        } catch {
            NSLog("PRMaster: syntax highlighting is off, shiki.js did not load: %@", String(describing: error))
            loaded = .some(nil)
        }
        return loaded ?? nil
    }
}
