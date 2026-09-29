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
    private var keyMonitors: [String: Any] = [:]
    private let highlighter = BundledHighlighter()

    func show(
        _ subject: DiffSubject,
        source: PullRequestDiffing?,
        viewedWriter: PullRequestDiffing?,
        appearance: AppearanceStore,
        live: @escaping () -> DiffLiveState,
        onAct: @escaping (MergeTarget, _ close: @escaping () -> Void) -> Void,
        onOpen: @escaping (URL) -> Void
    ) {
        let (panel, isNew) = registry.window(for: subject.id) {
            makePanel(subject, source: source, viewedWriter: viewedWriter, appearance: appearance,
                      live: live, onAct: onAct, onOpen: onOpen)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // AppKit hands a new key window's first text field the focus, which here is the file filter.
        if isNew { DispatchQueue.main.async { panel.makeFirstResponder(nil) } }
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
        let store = DiffStore(repo: subject.repo, number: subject.number, source: source,
                              viewedWriter: viewedWriter, highlighter: highlighter)
        let hosting = NSHostingController(rootView: DiffWindowView(
            store: store,
            subject: subject,
            live: live,
            appearance: appearance,
            onAct: { target in onAct(target) { weakPanel?.close() } },
            onOpenOnGitHub: { onOpen(subject.url) },
            initialFile: Debug.openFile
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
        // A text field's field editor takes Control-F as "move forward" before
        // any SwiftUI shortcut sees it, so the window listens first.
        keyMonitors[subject.id] = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === weakPanel,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
                  event.charactersIgnoringModifiers?.lowercased() == "f" else { return event }
            store.openFind()
            return nil
        }
        return panel
    }

    func snapshotFrontWindow(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.delegate === self && $0.isVisible }) else { return }
        Debug.snapshot(window, to: url)
    }

    func windowWillClose(_ notification: Notification) {
        guard let key = (notification.object as? NSWindow)?.identifier?.rawValue else { return }
        registry.remove(key)
        keyMonitors.removeValue(forKey: key).map(NSEvent.removeMonitor)
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
