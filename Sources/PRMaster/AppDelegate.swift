import AppKit
import SwiftUI
import PRMasterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var store: PRStore!
    private var client: GitHubClient!
    private var merger: MergeCoordinator!
    private var updates: AppUpdateStore!
    private let settingsWindow = SettingsWindowController()
    private var observers: [NSObjectProtocol] = []
    private var dismissMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        client = GitHubClient()
        // Merging always goes through the real client, even under a fixture:
        // only fetching is ever faked.
        var fetcher: PullRequestFetching =
            Debug.fakeError.map { FailingClient(error: $0) as PullRequestFetching }
            ?? Debug.fixturePath.map { FixtureClient(path: $0) as PullRequestFetching }
            ?? client
        if let n = Debug.failAfter {
            fetcher = FlakyClient(
                base: fetcher, successes: n, error: .network(URLError(.timedOut))
            )
        }
        // Merging is refused outright while any debug override is active: the
        // displayed rows may carry real node IDs from a captured fixture.
        if Debug.demoMerge != nil {
            // Demonstrates the dialogs against a no-op merger: real UI, no API.
            merger = MergeCoordinator(client: NoopMerger(), mergingAllowed: true)
        } else {
            merger = MergeCoordinator(client: client, mergingAllowed: !Debug.overridesActive)
        }

        store = PRStore(
            client: fetcher,
            notifier: NotificationManager.shared,
            idStore: UserDefaultsIDStore(),
            // Never under a debug override. The same reasoning as the merge
            // gate, only sharper: a fixture row carries a real node ID and a
            // real head oid, and this path writes to GitHub off a timer with
            // no click anywhere in it.
            updater: Debug.overridesActive ? nil : client,
            preferences: UserDefaultsPreferences()
        )

        updates = AppUpdateStore(
            checker: ReleaseClient(),
            // Read from the bundle, not from PRMasterCore.version, which is a
            // second copy of the number that nothing keeps in step.
            currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                as? String ?? "0.0.0",
            // Never under a debug override. Sharper than the merge and branch
            // gates: this path does not write to GitHub, it replaces this app's
            // own bundle on disk.
            installer: Debug.overridesActive ? nil : AppUpdateInstaller()
        )

        // Registered before this method returns: a category set up after the
        // first delivery means the Open and Merge buttons never appear.
        NotificationManager.shared.register(
            onOpen: { [weak self] url in self?.open(url) },
            onMerge: { [weak self] id, oid, title, url in
                self?.confirmMerge(id: id, oid: oid, title: title, url: url)
            }
        )

        installStatusItem()
        installPopover()
        observeWake()
        observeStoreForBadge()

        store.start()
        // Started after the PR poll so the first update check never competes
        // with the fetch the user is actually waiting to see.
        updates.start()

        if Debug.openSettings {
            settingsWindow.show(store: store)
        }

        // Under a fixture, open straight away so the UI can be inspected and
        // screenshotted without clicking the menu bar.
        if Debug.fixturePath != nil || Debug.fakeError != nil || Debug.autoOpen {
            Task { @MainActor in
                // The status item needs a laid-out window before the popover
                // can anchor to it, and the app must be active or the popover
                // is positioned as if it had no anchor at all.
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .seconds(1))
                self.togglePopover()

                switch Debug.demoMerge {
                case "confirm":
                    self.confirmMerge(
                        id: "PR_demo", oid: "abc123",
                        title: "paginate the widget catalogue endpoint",
                        url: URL(string: "https://github.com/acme/widget-service/pull/1204")!
                    )
                case "fail":
                    self.presentMergeFailure(
                        "Head branch was modified. Review and try the merge again.",
                        url: URL(string: "https://github.com/acme/widget-service/pull/1204")!
                    )
                default:
                    break
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
        updates?.stop()
        // Must match the centre it was registered on, or removal is a no-op.
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    // MARK: - Status item

    private func installStatusItem() {
        // withLength: takes a CGFloat, so the constant needs its type spelled out.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "arrow.triangle.pull",
            accessibilityDescription: "PR Master Tray"
        )
        item.button?.imagePosition = .imageLeading
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        // A status item button reports only the left button unless asked. The
        // alternative — assigning `item.menu` — would hand *both* clicks to the
        // menu, and the popover would never open at all.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    /// Left click opens the popover, right click the menu below it.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        // Control-click is the system's other route to a context menu, and it
        // arrives as a left click with a modifier rather than as a right one.
        let wantsMenu =
            event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if wantsMenu {
            showStatusItemMenu()
        } else {
            togglePopover()
        }
    }

    /// The right-click menu: the two things worth reaching without first opening
    /// the popover.
    ///
    /// Both are also in the popover's gear menu — this is a shortcut to them, not
    /// a second home for them, so anything longer belongs there and not here.
    private func showStatusItemMenu() {
        guard let item = statusItem, let button = item.button else { return }

        // The global dismiss monitor never sees this click — global monitors skip
        // our own app's events — so the popover has to be closed by hand or it
        // stays up behind the menu.
        popover.performClose(nil)

        let menu = NSMenu()
        menu.addItem(menuItem("Settings…", #selector(openSettingsFromMenu)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit PR Master Tray", #selector(quitFromMenu)))

        // Assigned, clicked, then cleared. `NSMenu.popUp(positioning:at:in:)` on
        // the button draws the menu detached from the item and leaves the item
        // unhighlighted; handing it to the status item is what makes it look like
        // every other menu bar menu. Menu tracking is modal, so the line that
        // gives the left click its action back runs once the menu closes.
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        // Without a target the item is dimmed: an LSUIElement app has no menu bar
        // and so no responder chain to find these on.
        item.target = self
        return item
    }

    @objc private func openSettingsFromMenu() {
        settingsWindow.show(store: store)
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    /// NSStatusItem has no badge API, so the ready count rides on the button
    /// title next to the glyph.
    private func observeStoreForBadge() {
        withObservationTracking {
            _ = store.readyCount
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateBadge()
                self?.observeStoreForBadge()
            }
        }
    }

    private func updateBadge() {
        let count = store.readyCount
        statusItem?.button?.title = count > 0 ? " \(count)" : ""
    }

    // MARK: - Popover

    private func installPopover() {
        // Kept for the cases it does handle — Cmd-Tab away, a click on another
        // window of ours — but it is not what dismisses an outside click. See
        // installDismissMonitors().
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        let hosting = NSHostingController(
            rootView: PRListView(
                store: store,
                onOpen: { [weak self] pr in
                    self?.open(pr.url)
                    self?.popover.performClose(nil)
                },
                onMerge: { [weak self] pr in
                    self?.confirmMerge(
                        id: pr.id, oid: pr.headRefOid, title: pr.displayTitle, url: pr.url
                    )
                },
                onOpenSettings: { [weak self] in
                    guard let self else { return }
                    // Closed explicitly rather than left to `.transient`: the
                    // panel activates the app, and two things fighting over who
                    // is key is how the popover ends up half-dismissed.
                    popover.performClose(nil)
                    settingsWindow.show(store: store)
                },
                onQuit: { NSApp.terminate(nil) },
                canMerge: Debug.mergingOffered,
                canAutoUpdate: !Debug.overridesActive,
                notifications: NotificationStatus.shared,
                updates: updates
            )
        )
        // Without this the popover sizes itself once from a stale measurement
        // and anchors against it, pushing the header off the top of the screen.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        guard !popover.isShown else {
            popover.performClose(nil)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)

        // An accessory app is not active when its status item is clicked, so
        // the popover's window is not key: the first click inside only wakes
        // the process and the control never sees it. That is the whole of the
        // "have to click it twice" problem.
        //
        // `ignoringOtherApps:` rather than the newer no-argument `activate()`:
        // under macOS's cooperative activation the plain form can be declined,
        // and being declined here puts the second click straight back. It is
        // discouraged in the documentation but not deprecated in the SDK, and
        // it is what the alerts in this file already use.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        installDismissMonitors()

        // Opening the popover is an explicit "show me now", so don't make
        // the user wait out the remainder of the poll interval.
        Task {
            await NotificationManager.shared.refreshAuthorizationStatus()
            await store.refresh()
        }
    }

    /// Closes the popover on a click anywhere else, or on Escape.
    ///
    /// `.transient` dismisses by watching for the app to resign active, which
    /// is precisely what an accessory app that never activated cannot do — the
    /// original bug. Activating above restores that route, but activation is a
    /// request the system is allowed to decline, so this does not depend on it:
    /// the monitor observes the click itself.
    private func installDismissMonitors() {
        guard dismissMonitors.isEmpty else { return }

        // Mouse buttons only. Adding .keyDown to a *global* monitor would make
        // macOS demand accessibility access — this app has no business asking
        // for the ability to watch every keystroke on the machine.
        let outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                Task { @MainActor in self?.popover.performClose(nil) }
            }
        )

        // Local, so Escape costs no permission at all.
        let escape = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                guard event.keyCode == 53 else { return event }  // Escape
                self?.popover.performClose(nil)
                return nil
            }
        )

        dismissMonitors = [outsideClick, escape].compactMap { $0 }
    }

    // MARK: - Wake

    /// After sleep the timer has been suspended and the data is stale by
    /// however long the lid was shut.
    private func observeWake() {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await NotificationManager.shared.refreshAuthorizationStatus()
                await self?.store.refresh()
            }
        }
        observers.append(observer)
    }

    // MARK: - Actions

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Merging is irreversible and can be triggered from a notification, so it
    /// always goes through an explicit confirmation.
    func confirmMerge(id: String, oid: String, title: String, url: URL) {
        Task { @MainActor in
            let outcome = await merger.attempt(id: id, expectedHeadOid: oid) {
                self.askToMerge(title: title)
            }

            switch outcome {
            case .merged:
                await store.refresh()
            case .cancelled:
                break
            case .refusedDebugOverride:
                presentRefusal()
            case .failed(let message):
                presentMergeFailure(message, url: url)
            }
        }
    }

    /// The confirmation sheet. Returns true only if the user chose Merge.
    private func askToMerge(title: String) -> Bool {
        // An LSUIElement app shows no dialog unless it activates first.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Squash and merge this pull request?"
        alert.informativeText = title
        alert.alertStyle = .warning

        let merge = alert.addButton(withTitle: "Merge")
        let cancel = alert.addButton(withTitle: "Cancel")
        // AppKit gives Return to the first button added, which would make the
        // irreversible action the default. Activating the app steals focus, so
        // a stray Return aimed elsewhere would land here.
        merge.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentRefusal() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Merging is disabled"
        alert.informativeText = """
            PR Master Tray is showing data from a debug override, so these \
            rows may not correspond to real pull requests. Restart without \
            PRMASTER_FIXTURE, PRMASTER_FAKE_ERROR, PRMASTER_FAIL_AFTER or \
            PRMASTER_DEMO_MERGE to merge.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentMergeFailure(_ message: String, url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't merge"
        // GitHub's own wording — "head branch was modified" is exactly what
        // the user needs to see, and a paraphrase would obscure it.
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open in GitHub")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            open(url)
        }
        // The refusal usually means our snapshot is out of date, so get a
        // fresh one rather than leaving a stale row on screen.
        Task { await store.refresh() }
    }
}

extension AppDelegate: NSPopoverDelegate {

    /// The single teardown point for the dismiss monitors.
    ///
    /// Every route out of the popover lands here — the outside click, Escape,
    /// the status item toggling it shut, opening a PR, and `.transient` closing
    /// it without consulting any of our code. A global event monitor that
    /// outlived its popover would keep firing for the life of the app.
    func popoverDidClose(_ notification: Notification) {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
    }
}
