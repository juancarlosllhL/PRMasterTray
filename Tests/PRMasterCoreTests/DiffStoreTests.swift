import Foundation
import Testing
@testable import PRMasterCore

private final class StubDiffSource: PullRequestDiffing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<PullRequestDiff, Error>
    private var failure: Error?
    private var writes: [(path: String, viewed: Bool)] = []

    init(_ result: Result<PullRequestDiff, Error>, viewedError: Error? = nil) {
        self.result = result
        self.failure = viewedError
    }

    var viewedError: Error? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var viewedWrites: [(path: String, viewed: Bool)] { lock.withLock { writes } }

    func loadDiff(repo: String, number: Int) async throws -> PullRequestDiff {
        try result.get()
    }

    func setViewed(pullRequestID: String, path: String, viewed: Bool) async throws {
        lock.withLock { writes.append((path, viewed)) }
        if let viewedError { throw viewedError }
    }
}

private func file(_ path: String, viewed: ViewedState = .unviewed, text: String = "a") -> DiffFile {
    DiffFile(
        path: path, previousPath: nil, change: .modified, additions: 1, deletions: 1,
        content: .hunks([Hunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, context: "",
            lines: [DiffLine(kind: .removed, oldNumber: 1, newNumber: nil, text: text),
                    DiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "b")]
        )]),
        viewed: viewed
    )
}

private func diff(head: String = "H1", truncated: Bool = false, files: [DiffFile] = [file("a.swift")]) -> PullRequestDiff {
    PullRequestDiff(pullRequestID: "PR_1", baseOid: "B1", headOid: head, files: files, isTruncated: truncated)
}

@MainActor
private func loadedStore(
    _ value: PullRequestDiff = diff(), viewedError: Error? = nil, writer: Bool = true,
    highlighter: SyntaxHighlighting? = nil, preferences: PreferenceStoring = MemoryPreferences()
) async -> (DiffStore, StubDiffSource) {
    let source = StubDiffSource(.success(value), viewedError: viewedError)
    let store = DiffStore(
        repo: "acme/widget", number: 7, source: source, viewedWriter: writer ? source : nil,
        highlighter: highlighter, preferences: preferences
    )
    await store.load()
    return (store, source)
}

@MainActor
@Suite("DiffStore")
struct DiffStoreTests {

    @Test("a store starts loading and is loaded once the diff arrives")
    func loads() async {
        let source = StubDiffSource(.success(diff()))
        let store = DiffStore(repo: "acme/widget", number: 7, source: source, viewedWriter: source,
                              preferences: MemoryPreferences())
        #expect(store.phase == .loading)
        await store.load()
        #expect(store.phase == .loaded)
        #expect(store.diff?.files.map(\.path) == ["a.swift"])
        #expect(!store.rows.isEmpty)
    }

    @Test("a failed load shows GitHub's own words")
    func failureKeepsGitHubsMessage() async {
        let source = StubDiffSource(.failure(PRMasterError.graphQL(["Could not resolve to a PullRequest"])))
        let store = DiffStore(repo: "acme/widget", number: 7, source: source, viewedWriter: nil,
                              preferences: MemoryPreferences())
        await store.load()
        #expect(store.phase == .failed("Could not resolve to a PullRequest"))
    }

    @Test("with no source, as under a debug override, the store says why nothing loaded")
    func noSource() async {
        let store = DiffStore(repo: "acme/widget", number: 7, source: nil, viewedWriter: nil,
                              preferences: MemoryPreferences())
        await store.load()
        guard case .failed = store.phase else {
            Issue.record("expected a failure, got \(store.phase)")
            return
        }
    }

    @Test("marking a file viewed shows at once, collapses it, and reaches GitHub")
    func viewedApplies() async {
        let (store, source) = await loadedStore()
        await store.setViewed("a.swift", true)
        #expect(store.diff?.files[0].viewed == .viewed)
        #expect(store.collapsed.contains("a.swift"))
        #expect(source.viewedWrites.map(\.path) == ["a.swift"])
    }

    @Test("a refused viewed toggle reverts and says so on that file")
    func viewedReverts() async {
        let (store, _) = await loadedStore(viewedError: PRMasterError.graphQL(["Resource not accessible"]))
        await store.setViewed("a.swift", true)
        #expect(store.diff?.files[0].viewed == .unviewed)
        #expect(!store.collapsed.contains("a.swift"))
        #expect(store.viewedFailures["a.swift"] == "Resource not accessible")
    }

    @Test("a successful toggle clears an earlier failure on that file")
    func viewedFailureClears() async {
        let (store, source) = await loadedStore(viewedError: PRMasterError.graphQL(["nope"]))
        await store.setViewed("a.swift", true)
        #expect(store.viewedFailures["a.swift"] == "nope")
        source.viewedError = nil
        await store.setViewed("a.swift", true)
        #expect(store.viewedFailures.isEmpty)
        #expect(store.diff?.files[0].viewed == .viewed)
    }

    @Test("with no writer the toggle is refused and nothing is sent")
    func noWriterRefuses() async {
        let (store, source) = await loadedStore(writer: false)
        #expect(!store.canMarkViewed)
        await store.setViewed("a.swift", true)
        #expect(store.diff?.files[0].viewed == .unviewed)
        #expect(source.viewedWrites.isEmpty)
    }

    @Test("files already viewed on GitHub open collapsed")
    func viewedStartCollapsed() async {
        let (store, _) = await loadedStore(diff(files: [file("a.swift", viewed: .viewed), file("b.swift")]))
        #expect(store.collapsed == ["a.swift"])
    }

    @Test("a live head that differs from the diff's means new commits arrived")
    func headMoved() async {
        let (store, _) = await loadedStore()
        store.observe(liveHead: "H2", isReady: true)
        #expect(store.phase == .headMoved)
    }

    @Test("a live row that is gone means the pull request was merged or closed elsewhere")
    func closed() async {
        let (store, _) = await loadedStore()
        store.observe(liveHead: nil, isReady: false)
        #expect(store.phase == .closed)
    }

    @Test("an observation that arrives before the diff still applies once it loads")
    func observationBeforeLoad() async {
        let source = StubDiffSource(.success(diff()))
        let store = DiffStore(repo: "acme/widget", number: 7, source: source, viewedWriter: source,
                              preferences: MemoryPreferences())
        store.observe(liveHead: "H2", isReady: true)
        await store.load()
        #expect(store.phase == .headMoved)
    }

    @Test(
        "merge is offered only on a loaded, current, complete diff of a ready pull request",
        arguments: [
            ("H1", true, false, true),
            ("H1", false, false, false),
            ("H2", true, false, false),
            ("H1", true, true, false),
        ]
    )
    func mergeTargetGate(liveHead: String, isReady: Bool, truncated: Bool, offered: Bool) async {
        let (store, _) = await loadedStore(diff(truncated: truncated))
        store.observe(liveHead: liveHead, isReady: isReady)
        #expect((store.mergeTarget != nil) == offered)
    }

    @Test("nothing is offered before the diff has loaded")
    func noTargetWhileLoading() {
        let source = StubDiffSource(.success(diff()))
        let store = DiffStore(repo: "acme/widget", number: 7, source: source, viewedWriter: source,
                              preferences: MemoryPreferences())
        store.observe(liveHead: "H1", isReady: true)
        #expect(store.mergeTarget == nil)
    }

    /// The whole point of the window: what gets merged is what was read.
    @Test("the merge target is the reviewed commit, not whatever the row says now")
    func targetIsReviewedCommit() async {
        let (store, _) = await loadedStore(diff(head: "REVIEWED"))
        store.observe(liveHead: "REVIEWED", isReady: true)
        #expect(store.mergeTarget == MergeTarget(id: "PR_1", oid: "REVIEWED"))
    }

    @Test("switching layout rebuilds the rows and remembers the choice")
    func layoutPersists() async {
        let preferences = MemoryPreferences()
        let (store, _) = await loadedStore(preferences: preferences)
        let unified = store.rows
        store.layout = .split
        #expect(preferences.diffLayout() == .split)
        #expect(store.rows != unified)
    }

    private func twoNeedles() -> PullRequestDiff {
        diff(files: [file("a.swift", text: "needle"), file("b.swift", text: "Needle")])
    }

    @Test("a find query lands on the first match, and next and previous wrap around")
    func findNavigation() async {
        let (store, _) = await loadedStore(twoNeedles())
        store.findQuery = "needle"
        #expect(store.findMatches.count == 2)
        #expect(store.currentFindIndex == 0)
        store.findNext()
        #expect(store.currentFindIndex == 1)
        store.findNext()
        #expect(store.currentFindIndex == 0)
        store.findPrevious()
        #expect(store.currentFindIndex == 1)
        #expect(store.currentFindMatch == store.findMatches[1])
    }

    @Test("no matches means no current match, and moving does nothing")
    func findNothing() async {
        let (store, _) = await loadedStore(twoNeedles())
        store.findQuery = "haystack"
        store.findNext()
        #expect(store.findMatches.isEmpty)
        #expect(store.currentFindIndex == nil)
        #expect(store.currentFindMatch == nil)
    }

    /// Matches point at row numbers, so anything that rebuilds the rows must
    /// search again or the highlight lands on the wrong line.
    @Test("collapsing a file or switching layout searches the new rows")
    func findFollowsRows() async {
        let (store, _) = await loadedStore(twoNeedles())
        store.findQuery = "needle"
        store.findNext()
        store.toggleCollapsed("b.swift")
        #expect(store.findMatches.count == 1)
        #expect(store.currentFindIndex == 0)
        store.toggleCollapsed("b.swift")
        store.layout = .split
        #expect(store.findMatches.count == 2)
        #expect(store.findMatches.allSatisfy { match in
            if case .pair(let left, _) = store.rows[match.row] { return left?.text.lowercased() == "needle" }
            return false
        })
    }

    @Test("closing the find bar clears the query and every highlight")
    func findClosed() async {
        let (store, _) = await loadedStore(twoNeedles())
        store.openFind()
        #expect(store.isFinding)
        store.findQuery = "needle"
        store.closeFind()
        #expect(!store.isFinding)
        #expect(store.findQuery.isEmpty)
        #expect(store.findMatches.isEmpty)
    }

    @Test("clearing the query clears the matches")
    func findCleared() async {
        let (store, _) = await loadedStore(twoNeedles())
        store.findQuery = "needle"
        store.findQuery = ""
        #expect(store.findMatches.isEmpty)
        #expect(store.currentFindIndex == nil)
    }

    @Test("a new store opens in the layout chosen last time")
    func layoutReadAtLaunch() {
        let preferences = MemoryPreferences()
        preferences.setDiffLayout(.split)
        let store = DiffStore(repo: "acme/widget", number: 7, source: nil, viewedWriter: nil, preferences: preferences)
        #expect(store.layout == .split)
    }

    @Test("an absent or unrecognised stored layout reads as unified")
    func layoutDefault() {
        let name = "DiffStoreTests.layoutDefault"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        #expect(UserDefaultsPreferences(defaults: defaults).diffLayout() == .unified)
        defaults.set("sideways", forKey: "diffLayout")
        #expect(UserDefaultsPreferences(defaults: defaults).diffLayout() == .unified)
    }

    @Test("a stored layout survives a round trip", arguments: DiffLayout.allCases)
    func layoutRoundTrip(layout: DiffLayout) {
        let name = "DiffStoreTests.roundTrip.\(layout.rawValue)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setDiffLayout(layout)
        #expect(preferences.diffLayout() == layout)
    }
    // MARK: - Scope

    private static let testsScope = FileScope(patterns: [.tests: ["*_test.go"]])

    private func scopedStore() async -> (DiffStore, StubDiffSource) {
        let (store, source) = await loadedStore(diff(files: [
            file("a.go"), file("b.go", viewed: .viewed),
            file("a_test.go", text: "needle"), file("c_test.go", viewed: .viewed),
        ]))
        store.setScope(Self.testsScope)
        return (store, source)
    }

    @Test("set-aside files open collapsed whatever GitHub says; review files follow viewed")
    func scopeCollapsesSetAside() async {
        let (store, _) = await scopedStore()
        #expect(store.groups == [
            DiffFileGroup(section: .review, files: Array(store.diff!.files[0...1])),
            DiffFileGroup(section: .tests, files: Array(store.diff!.files[2...3])),
        ])
        #expect(store.collapsed == ["b.go", "a_test.go", "c_test.go"])
        #expect(store.rows.contains(.section(.tests, count: 2)))
    }

    @Test("opening one set-aside file leaves the others closed")
    func scopeToggleOne() async {
        let (store, _) = await scopedStore()
        store.toggleCollapsed("a_test.go")
        #expect(!store.isCollapsed("a_test.go"))
        #expect(store.isCollapsed("c_test.go"))
        store.toggleCollapsed("a_test.go")
        #expect(store.isCollapsed("a_test.go"))
    }

    /// Settings reclassify open windows on every keystroke, so a pattern typed
    /// and then deleted must leave every file as the reader had it.
    @Test("changing the scope and changing it back restores every file's state")
    func scopeRoundTrip() async {
        let (store, _) = await scopedStore()
        store.toggleCollapsed("a_test.go")
        store.toggleCollapsed("a.go")
        let before = store.collapsed
        store.setScope(FileScope(patterns: [:]))
        #expect(store.groups.map(\.section) == [.review])
        #expect(!store.rows.contains { if case .section = $0 { return true } else { return false } })
        store.setScope(FileScope(patterns: [.tests: ["*.go"]]))
        store.setScope(Self.testsScope)
        #expect(store.collapsed == before)
    }

    @Test("marking a set-aside file viewed closes it again")
    func scopeViewedCollapses() async {
        let (store, _) = await scopedStore()
        store.toggleCollapsed("a_test.go")
        await store.setViewed("a_test.go", true)
        #expect(store.isCollapsed("a_test.go"))
    }

    @Test("counts cover only what they name")
    func scopeCounts() async {
        let (store, _) = await scopedStore()
        #expect(store.reviewFiles.map(\.path) == ["a.go", "b.go"])
        #expect(store.viewedReviewCount == 1)
        #expect(store.setAsideCount == 2)
    }

    @Test("find skips set-aside files until one is opened")
    func scopeFind() async {
        let (store, _) = await scopedStore()
        store.findQuery = "needle"
        #expect(store.findMatches.isEmpty)
        store.toggleCollapsed("a_test.go")
        #expect(store.findMatches.count == 1)
    }

    @Test("an equal scope changes nothing, so re-renders do not rebuild the rows")
    func scopeIdempotent() async {
        let (store, _) = await scopedStore()
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = store.rows } onChange: { changed = true }
        store.setScope(FileScope(patterns: [.tests: ["*_test.go"]]))
        #expect(!changed)
    }

    @Test("review files are coloured before set-aside ones")
    func scopeHighlightOrder() async {
        let highlighter = GatedHighlighter(open: true)
        let source = StubDiffSource(.success(diff(files: [file("a_test.go"), file("a.go")])))
        let store = DiffStore(repo: "acme/widget", number: 7, source: source, viewedWriter: source,
                              highlighter: highlighter, preferences: MemoryPreferences())
        store.setScope(Self.testsScope)
        await store.load()
        await store.highlightingFinished()
        #expect(await highlighter.asked == ["a.go", "a_test.go"])
    }

}

/// The real highlighter behind a gate, recording which files it is asked for and in what order.
private actor GatedHighlighter: SyntaxHighlighting {
    private var isOpen: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var asked: [String] = []

    init(open: Bool) { isOpen = open }

    func highlight(_ file: DiffFile, theme: SyntaxTheme) async -> DiffFile {
        asked.append(file.path)
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        return await ShikiScript.highlighter.highlight(file, theme: theme)
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func waitUntilAsked() async {
        while asked.isEmpty { await Task.yield() }
    }
}

@MainActor
private func tokens(_ store: DiffStore, _ path: String) -> [TokenRange] {
    guard let file = store.diff?.files.first(where: { $0.path == path }), case .hunks(let hunks) = file.content
    else { return [] }
    return hunks.flatMap(\.lines).flatMap(\.tokens)
}

@MainActor
@Suite("DiffStore highlighting")
struct DiffStoreHighlightingTests {

    @Test("rows show plain text at once and gain colour in the background")
    func plainThenColoured() async {
        let (store, _) = await loadedStore(diff(files: [file("a.swift", text: "let a")]),
                                           highlighter: ShikiScript.highlighter)
        #expect(store.phase == .loaded)
        #expect(tokens(store, "a.swift").isEmpty)
        await store.highlightingFinished()
        #expect(!tokens(store, "a.swift").isEmpty)
        #expect(store.rows.contains {
            guard case .line(let line) = $0 else { return false }
            return !line.tokens.isEmpty
        })
    }

    @Test("the file asked for first is highlighted before the ones above it")
    func prioritised() async {
        let highlighter = GatedHighlighter(open: true)
        let files = ["a.swift", "b.swift", "c.swift"].map { file($0, text: "let a") }
        let (store, _) = await loadedStore(diff(files: files), highlighter: highlighter)
        store.prioritise("c.swift")
        await store.highlightingFinished()
        #expect(await highlighter.asked == ["c.swift", "a.swift", "b.swift"])
    }

    @Test("files no grammar reads are never sent to the highlighter")
    func unknownLanguagesSkipped() async {
        let highlighter = GatedHighlighter(open: true)
        let files = [file("notes.xyz", text: "let a"), file("a.swift", text: "let a")]
        let (store, _) = await loadedStore(diff(files: files), highlighter: highlighter)
        await store.highlightingFinished()
        #expect(await highlighter.asked == ["a.swift"])
    }

    @Test("a new theme recolours every file in that theme")
    func themeChange() async {
        let files = [file("a.swift", text: "let a"), file("b.swift", text: "let b")]
        let (store, _) = await loadedStore(diff(files: files), highlighter: ShikiScript.highlighter)
        await store.highlightingFinished()
        let light = tokens(store, "a.swift").map(\.colour)

        store.setTheme(.dark)
        await store.highlightingFinished()
        let dark = Set(await ShikiScript.highlighter.colours(of: .dark))
        #expect(tokens(store, "a.swift").map(\.colour) != light)
        for path in ["a.swift", "b.swift"] {
            #expect(!tokens(store, path).isEmpty)
            #expect(tokens(store, path).allSatisfy { dark.contains($0.colour) }, "\(path)")
        }
    }

    @Test("switching layout while highlighting keeps what is already coloured")
    func layoutSwitch() async {
        let highlighter = GatedHighlighter(open: false)
        let (store, _) = await loadedStore(diff(files: [file("a.swift", text: "let a")]), highlighter: highlighter)
        await highlighter.waitUntilAsked()
        store.layout = .split
        await highlighter.open()
        await store.highlightingFinished()
        store.layout = .unified
        store.layout = .split
        #expect(store.rows.contains {
            guard case .pair(let left, _) = $0 else { return false }
            return left?.tokens.isEmpty == false
        })
    }

    @Test("marking a file viewed while it is being highlighted sticks")
    func viewedDuringHighlight() async {
        let highlighter = GatedHighlighter(open: false)
        let (store, _) = await loadedStore(diff(files: [file("a.swift", text: "let a")]), highlighter: highlighter)
        await highlighter.waitUntilAsked()
        await store.setViewed("a.swift", true)
        await highlighter.open()
        await store.highlightingFinished()
        #expect(store.diff?.files.first?.viewed == .viewed)
        #expect(store.collapsed.contains("a.swift"))
        #expect(!tokens(store, "a.swift").isEmpty)
    }

}
