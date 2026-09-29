import AppKit
import PRMasterCore
import WebKit

/// Serves PRs from a local JSON file instead of GitHub.
///
/// Exists because the app's headline behaviour — a PR turning green and
/// notifying — is otherwise unverifiable on demand: it needs a real reviewer
/// to approve a real PR at the right moment. Set `PRMASTER_FIXTURE` to a
/// search-response JSON file to drive the UI deterministically.
///
/// Only fetching is faked. Merging always goes to the real API, so this can
/// never cause a merge that would not otherwise have happened.
struct FixtureClient: PullRequestFetching {
    let path: String

    func fetchMyPullRequests(mergedWindow: MergedWindow) async throws -> PullRequestSnapshot {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let tallies = threadTallies()
        return PullRequestSnapshot(
            open: try PullRequestDecoder.decodeSearch(data).map { $0.with(threads: tallies[$0.id]) },
            // Tolerated rather than required: a fixture captured before the
            // merged half existed still drives the open list, and simply shows
            // no merged rows. This is a debug-only path, so the alternative —
            // refusing to render anything — costs more than it protects.
            merged: (try? PullRequestDecoder.decodeMergedSearch(data)) ?? []
        )
    }

    /// Read from `<fixture>.threads.json` beside the fixture, when there is one.
    private func threadTallies() -> [String: ReviewThreadTally] {
        let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("threads.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PullRequestDecoder.decodeReviewThreads(data)) ?? [:]
    }
}

/// Always fails, so the error states can be inspected on demand.
struct FailingClient: PullRequestFetching {
    let error: PRMasterError
    func fetchMyPullRequests(mergedWindow: MergedWindow) async throws -> PullRequestSnapshot { throw error }
}

/// Succeeds `successes` times then fails forever.
///
/// The stale banner is the app's subtlest state — real data plus a failed
/// refresh — and is otherwise only reachable by pulling the network cable at
/// exactly the right moment.
final class FlakyClient: PullRequestFetching, @unchecked Sendable {
    private let base: PullRequestFetching
    private let error: PRMasterError
    private let lock = NSLock()
    private var remaining: Int

    init(base: PullRequestFetching, successes: Int, error: PRMasterError) {
        self.base = base
        self.remaining = successes
        self.error = error
    }

    func fetchMyPullRequests(mergedWindow: MergedWindow) async throws -> PullRequestSnapshot {
        let allowed = lock.withLock { () -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        guard allowed else { throw error }
        return try await base.fetchMyPullRequests(mergedWindow: mergedWindow)
    }
}

/// Accepts a merge and does nothing. Used only by PRMASTER_DEMO_MERGE, so the
/// confirmation dialog can be exercised without any call to GitHub.
struct NoopMerger: PullRequestMerging {
    func squashMerge(id: String, expectedHeadOid: String) async throws {}
}

enum Debug {
    /// Non-nil when `PRMASTER_FIXTURE` points at a readable file.
    static var fixturePath: String? {
        guard let path = ProcessInfo.processInfo.environment["PRMASTER_FIXTURE"],
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        return path
    }

    /// `PRMASTER_FAKE_ERROR=ghNotFound|notAuthenticated|network|notJSON` forces
    /// a failure so the setup and stale-banner states are reachable without
    /// having to uninstall gh, pull the network cable, or sit behind the proxy
    /// that answered in HTML for the one user who reported it.
    static var fakeError: PRMasterError? {
        switch ProcessInfo.processInfo.environment["PRMASTER_FAKE_ERROR"] {
        case "ghNotFound": return .ghNotFound
        case "notAuthenticated": return .notAuthenticated(detail: "forced")
        case "network": return .network(URLError(.notConnectedToInternet))
        case "notJSON": return .notJSON
        default: return nil
        }
    }

    /// `PRMASTER_FAIL_AFTER=n` with a fixture: serve the fixture n times, then
    /// fail, so the stale banner becomes reachable.
    static var failAfter: Int? {
        ProcessInfo.processInfo.environment["PRMASTER_FAIL_AFTER"].flatMap(Int.init)
    }

    /// True when the app is showing anything other than live GitHub data.
    ///
    /// Merging is refused in this state. Fixtures are routinely captured from
    /// live API responses, so a fixture row can carry a real node ID and a real
    /// head oid — merging from one would merge a real pull request, and
    /// expectedHeadOid would not stop it because the oid is real too.
    static var overridesActive: Bool {
        fixturePath != nil || fakeError != nil || failAfter != nil || demoMerge != nil || diffFixturePath != nil
    }

    /// `PRMASTER_AUTO_OPEN=1` opens the popover at launch, so the real-data
    /// path can be inspected without clicking the menu bar.
    static var autoOpen: Bool {
        ProcessInfo.processInfo.environment["PRMASTER_AUTO_OPEN"] == "1"
    }

    /// `PRMASTER_OPEN_SETTINGS=1` opens the settings window at launch. It is
    /// otherwise only reachable through the gear menu, which nothing but a real
    /// mouse can open — including whatever is taking the screenshots. Not part of
    /// `overridesActive`: it fakes no data, so it has no bearing on merging.
    static var openSettings: Bool {
        ProcessInfo.processInfo.environment["PRMASTER_OPEN_SETTINGS"] == "1"
    }

    /// `PRMASTER_WHATS_NEW=1` opens the changelog window, which otherwise only
    /// appears after an update to the release it describes.
    static var showWhatsNew: Bool {
        ProcessInfo.processInfo.environment["PRMASTER_WHATS_NEW"] == "1"
    }

    /// `PRMASTER_SETTINGS_TAB=pullRequests|appearance` selects which tab the
    /// settings window opens on. Same reason as `openSettings` one line up: a tab
    /// is a click, and a screenshot has no mouse. Falls through to the first tab
    /// for any unrecognised value, so a typo shows the default rather than nothing.
    static var settingsTab: String? {
        ProcessInfo.processInfo.environment["PRMASTER_SETTINGS_TAB"]
    }

    /// `PRMASTER_TAB=mine|teams|merged|jira` picks the popover pane, for the
    /// same reason `settingsTab` exists one line up.
    static var tab: String? {
        ProcessInfo.processInfo.environment["PRMASTER_TAB"]
    }

    /// `PRMASTER_JIRA_FIXTURE=<path>` serves captured issues, so the pane and
    /// its expandable rows can be inspected without live credentials.
    static var jiraFixturePath: String? {
        ProcessInfo.processInfo.environment["PRMASTER_JIRA_FIXTURE"]
            .flatMap { FileManager.default.isReadableFile(atPath: $0) ? $0 : nil }
    }

    /// `PRMASTER_DIFF_FIXTURE=<path>` serves a compare response to every review
    /// window, so the diff can be inspected without a network.
    static var diffFixturePath: String? {
        ProcessInfo.processInfo.environment["PRMASTER_DIFF_FIXTURE"]
            .flatMap { FileManager.default.isReadableFile(atPath: $0) ? $0 : nil }
    }

    /// `PRMASTER_OPEN_DIFF=<number>` opens that pull request's review window at
    /// launch. Fakes no data, so it is not an override.
    static var openDiff: Int? {
        ProcessInfo.processInfo.environment["PRMASTER_OPEN_DIFF"].flatMap(Int.init)
    }

    /// `PRMASTER_OPEN_FILE=<path>` selects that file in the review window's
    /// sidebar once it loads, the same as a click.
    static var openFile: String? {
        ProcessInfo.processInfo.environment["PRMASTER_OPEN_FILE"]
    }

    /// `PRMASTER_FILE_FILTER=<text>` types into the review window's file filter.
    static var fileFilter: String? {
        ProcessInfo.processInfo.environment["PRMASTER_FILE_FILTER"]
    }

    /// `PRMASTER_FIND=<text>` presses Control-F in the review window, types the
    /// text and presses Return once, through the real event queue.
    static var findQuery: String? {
        ProcessInfo.processInfo.environment["PRMASTER_FIND"]
    }

    @MainActor
    static func typeFind(_ query: String) {
        func post(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: modifiers.isEmpty ? characters : "f",
                    isARepeat: false, keyCode: code
                ) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            post("\u{06}", code: 3, modifiers: .control)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                for character in query { post(String(character), code: 0) }
                post("\r", code: 36)
            }
        }
    }

    /// `PRMASTER_SELECT=<x1>,<y1>,<x2>,<y2>` selects text between two points in visible-table coordinates.
    static var selectDrag: (NSPoint, NSPoint)? {
        let values = (ProcessInfo.processInfo.environment["PRMASTER_SELECT"] ?? "").split(separator: ",").compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        return (NSPoint(x: values[0], y: values[1]), NSPoint(x: values[2], y: values[3]))
    }

    /// `PRMASTER_SCROLL=<points>` scrolls that far past the file opened by
    /// `PRMASTER_OPEN_FILE`, to snapshot the middle of a file.
    static var scrollOffset: CGFloat? {
        ProcessInfo.processInfo.environment["PRMASTER_SCROLL"].flatMap(Double.init).map { CGFloat($0) }
    }

    /// `PRMASTER_SNAPSHOT=<path.png>` writes the review window opened by
    /// `PRMASTER_OPEN_DIFF` to disk, for screenshots without screen recording.
    static var snapshotPath: String? {
        ProcessInfo.processInfo.environment["PRMASTER_SNAPSHOT"]
    }

    @MainActor
    static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // `cacheDisplay` cannot see into a web view, so each one is painted over its own frame.
        let webViews = descendants(of: view).compactMap { $0 as? WKWebView }
        Task { @MainActor in
            for webView in webViews {
                guard let image = try? await webView.takeSnapshot(configuration: nil) else { continue }
                var frame = webView.convert(webView.bounds, to: view)
                if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
            }
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    /// `PRMASTER_DEMO_MERGE=confirm|fail` drives the merge dialogs directly,
    /// so the irreversible path can be inspected without a mergeable PR. Any
    /// other value swaps in the no-op merger without opening a dialog.
    static var demoMerge: String? {
        ProcessInfo.processInfo.environment["PRMASTER_DEMO_MERGE"]
    }

    /// Whether to offer the Merge affordances — the row button and the
    /// notification action.
    ///
    /// Normally the inverse of `overridesActive`, because a fixture row can name
    /// a real pull request and the merge would be refused. `PRMASTER_DEMO_MERGE`
    /// is the exception: it swaps in `NoopMerger`, so nothing can be merged and
    /// the affordances are both safe and the point. Without this, the one hook
    /// for demonstrating the merge path hid its own entry point.
    static var mergingOffered: Bool { !overridesActive || demoMerge != nil }
}
