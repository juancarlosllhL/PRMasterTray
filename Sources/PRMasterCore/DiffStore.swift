import Foundation
import Observation

public struct MergeTarget: Equatable, Sendable {
    public let id: String
    public let oid: String
}

/// State behind one diff window.
///
/// The live row from the popover's poll says whether the pull request is still
/// open and where its head is now; the diff never re-derives from it.
@MainActor
@Observable
public final class DiffStore {

    public enum Phase: Equatable, Sendable {
        case loading, loaded, failed(String), headMoved, closed
    }

    public private(set) var phase: Phase = .loading
    public private(set) var diff: PullRequestDiff?
    public private(set) var rows: [DiffRow] = []
    public private(set) var groups: [DiffFileGroup] = []
    public private(set) var scope = FileScope(patterns: [:])
    /// GitHub's message for the last viewed toggle it refused, by path.
    public private(set) var viewedFailures: [String: String] = [:]

    public var layout: DiffLayout {
        didSet {
            guard layout != oldValue else { return }
            preferences.setDiffLayout(layout)
            rebuildRows()
        }
    }

    public var findQuery = "" {
        didSet {
            guard findQuery != oldValue else { return }
            search(keepingPlace: false)
        }
    }
    public private(set) var isFinding = false
    public private(set) var findMatches: [DiffMatch] = []
    public private(set) var currentFindIndex: Int?

    public var currentFindMatch: DiffMatch? { currentFindIndex.map { findMatches[$0] } }

    public func openFind() { isFinding = true }

    public func closeFind() {
        isFinding = false
        findQuery = ""
    }

    public func findNext() { moveFind(by: 1) }
    public func findPrevious() { moveFind(by: -1) }

    private func moveFind(by step: Int) {
        guard let index = currentFindIndex, !findMatches.isEmpty else { return }
        currentFindIndex = (index + step + findMatches.count) % findMatches.count
    }

    private func search(keepingPlace: Bool) {
        findMatches = DiffSearch.matches(of: findQuery, in: rows)
        guard !findMatches.isEmpty else {
            currentFindIndex = nil
            return
        }
        currentFindIndex = keepingPlace ? min(currentFindIndex ?? 0, findMatches.count - 1) : 0
    }

    public var canMarkViewed: Bool { viewedWriter != nil }

    public var reviewFiles: [DiffFile] { groups.first { $0.section == .review }?.files ?? [] }
    public var viewedReviewCount: Int { reviewFiles.filter { $0.viewed == .viewed }.count }
    public var setAsideCount: Int { (diff?.files.count ?? 0) - reviewFiles.count }

    public var collapsed: Set<String> { Set((diff?.files ?? []).map(\.path).filter(isCollapsed)) }

    /// Review files stay open until viewed; set-aside files stay closed until opened.
    /// Both sets are kept whatever the scope, so a scope change undoes cleanly.
    public func isCollapsed(_ path: String) -> Bool {
        sections[path, default: .review] == .review ? collapsedReview.contains(path) : !expandedSetAside.contains(path)
    }

    public func setScope(_ scope: FileScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        classify()
        rebuildRows()
    }

    /// Nil unless what was read is still what GitHub would act on.
    public var mergeTarget: MergeTarget? {
        guard phase == .loaded, isReady, let diff, !diff.isTruncated else { return nil }
        return MergeTarget(id: diff.pullRequestID, oid: diff.headOid)
    }

    private let repo: String
    private let number: Int
    private let source: PullRequestDiffing?
    private let viewedWriter: PullRequestDiffing?
    private let preferences: PreferenceStoring
    private let highlighter: SyntaxHighlighting?
    private var liveHead: String??
    private var sections: [String: FileSection] = [:]
    private var collapsedReview: Set<String> = []
    private var expandedSetAside: Set<String> = []
    private var isReady = false

    @ObservationIgnored private var theme = SyntaxTheme.light
    @ObservationIgnored private var pendingHighlights: [String] = []
    @ObservationIgnored private var priorityPath: String?
    @ObservationIgnored private var highlighting: Task<Void, Never>?

    public init(
        repo: String, number: Int, source: PullRequestDiffing?, viewedWriter: PullRequestDiffing?,
        highlighter: SyntaxHighlighting? = nil, preferences: PreferenceStoring = UserDefaultsPreferences()
    ) {
        self.repo = repo
        self.number = number
        self.source = source
        self.viewedWriter = viewedWriter
        self.highlighter = highlighter
        self.preferences = preferences
        self.layout = preferences.diffLayout()
    }

    public func load() async {
        guard let source else {
            phase = .failed("Diffs aren't loaded while the app is showing debug data.")
            return
        }
        phase = .loading
        do {
            let loaded = try await source.loadDiff(repo: repo, number: number)
            diff = loaded
            collapsedReview = Set(loaded.files.filter { $0.viewed == .viewed }.map(\.path))
            expandedSetAside = []
            viewedFailures = [:]
            classify()
            rebuildRows()
            phase = .loaded
            evaluateLiveState()
            startHighlighting()
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Called with the popover's latest row: its head, or nil once it is gone.
    public func observe(liveHead: String?, isReady: Bool) {
        self.liveHead = .some(liveHead)
        self.isReady = isReady
        evaluateLiveState()
    }

    public func setViewed(_ path: String, _ viewed: Bool) async {
        guard let viewedWriter, let diff, let index = diff.files.firstIndex(where: { $0.path == path })
        else { return }
        let previous = diff.files[index].viewed
        apply(viewed ? .viewed : .unviewed, to: path)
        viewedFailures[path] = nil
        do {
            try await viewedWriter.setViewed(pullRequestID: diff.pullRequestID, path: path, viewed: viewed)
        } catch {
            apply(previous, to: path)
            viewedFailures[path] = Self.message(for: error)
        }
    }

    public func setTheme(_ theme: SyntaxTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        startHighlighting()
    }

    /// The file on screen, so it is coloured before the rest.
    public func prioritise(_ path: String) {
        priorityPath = path
        guard let index = pendingHighlights.firstIndex(of: path) else { return }
        pendingHighlights.insert(pendingHighlights.remove(at: index), at: 0)
    }

    func highlightingFinished() async {
        while let task = highlighting {
            await task.value
            if task == highlighting { return }
        }
    }

    private func startHighlighting() {
        highlighting?.cancel()
        guard highlighter != nil, let diff else { return }
        pendingHighlights = groups.flatMap(\.files).filter { file in
            guard case .hunks = file.content else { return false }
            return SyntaxLanguage.forPath(file.path) != nil
        }.map(\.path)
        if let priorityPath { prioritise(priorityPath) }
        let theme = theme
        // Weak between files, so closing the window stops the work after the file in flight.
        highlighting = Task { [weak self] in
            while !Task.isCancelled, await self?.highlightNextFile(theme: theme) == true {}
        }
    }

    private func highlightNextFile(theme: SyntaxTheme) async -> Bool {
        guard let highlighter, !pendingHighlights.isEmpty else { return false }
        let path = pendingHighlights.removeFirst()
        guard let file = diff?.files.first(where: { $0.path == path }) else { return true }
        var highlighted = await highlighter.highlight(file, theme: theme)
        guard !Task.isCancelled, let index = diff?.files.firstIndex(where: { $0.path == path }) else { return false }
        highlighted.viewed = diff?.files[index].viewed ?? highlighted.viewed
        diff?.files[index] = highlighted
        rebuildRows()
        return true
    }

    public func toggleCollapsed(_ path: String) {
        setCollapsed(path, !isCollapsed(path))
        rebuildRows()
    }

    private func setCollapsed(_ path: String, _ isCollapsed: Bool) {
        if isCollapsed {
            collapsedReview.insert(path)
            expandedSetAside.remove(path)
        } else {
            collapsedReview.remove(path)
            expandedSetAside.insert(path)
        }
    }

    private func apply(_ state: ViewedState, to path: String) {
        guard let index = diff?.files.firstIndex(where: { $0.path == path }) else { return }
        diff?.files[index].viewed = state
        setCollapsed(path, state == .viewed)
        rebuildRows()
    }

    private func evaluateLiveState() {
        guard let diff, let liveHead, phase == .loaded || phase == .headMoved || phase == .closed else { return }
        switch liveHead {
        case nil: phase = .closed
        case diff.headOid: phase = .loaded
        default: phase = .headMoved
        }
    }

    private func classify() {
        sections = Dictionary((diff?.files ?? []).map { ($0.path, scope.section(of: $0.path)) }, uniquingKeysWith: { $1 })
    }

    private func rebuildRows() {
        let files = diff?.files ?? []
        groups = FileSection.allCases.compactMap { section in
            let members = files.filter { sections[$0.path, default: .review] == section }
            return members.isEmpty ? nil : DiffFileGroup(section: section, files: members)
        }
        rows = DiffRows.build(groups: groups, layout: layout, isCollapsed: isCollapsed)
        search(keepingPlace: true)
    }

    private static func message(for error: Error) -> String {
        (error as? PRMasterError)?.errorDescription ?? error.localizedDescription
    }
}
