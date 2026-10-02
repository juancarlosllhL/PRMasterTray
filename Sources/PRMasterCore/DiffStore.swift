import Foundation
import Observation

/// Where a file stands with the heatmap.
public enum FileHeat: Equatable, Sendable {
    case waiting
    /// Its most important line; nil when the model scored none of them.
    case scored(Importance?)
    case failed(String)
}

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
    /// Every file with changed lines, once a scorer is set.
    public private(set) var heat: [String: FileHeat] = [:]
    public private(set) var heatmapEnabled = true

    /// Why scoring gave up on every file, when the key or the account is the problem.
    public private(set) var scoringStopped: String?

    /// Nothing is sent until the reviewer asks; after that, reloads in this window keep scoring.
    public private(set) var scoringRequested = false

    public var showsHeat: Bool { scorer != nil && heatmapEnabled && scoringRequested }
    public var canRequestScoring: Bool { scorer != nil && heatmapEnabled && !scoringRequested }

    public struct ScoringProgress: Equatable, Sendable {
        public let scored: Int
        public let total: Int
    }

    /// Nil once no file is waiting, so an unfinished heatmap never looks finished.
    public var scoringProgress: ScoringProgress? {
        let waiting = heat.values.filter { $0 == .waiting }.count
        return waiting == 0 ? nil : ScoringProgress(scored: heat.count - waiting, total: heat.count)
    }

    static let tooLargeMessage = "Part of this file is too large to score."

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

    public var viewedPaths: Set<String> { Set((diff?.files ?? []).filter { $0.viewed == .viewed }.map(\.path)) }

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
    private let scorer: BlockScoring?
    private let scoringRetryDelay: Duration
    private var liveHead: String??
    private var sections: [String: FileSection] = [:]
    private var collapsedReview: Set<String> = []
    private var expandedSetAside: Set<String> = []
    private var isReady = false

    @ObservationIgnored private var theme = SyntaxTheme.light
    @ObservationIgnored private var pendingHighlights: [String] = []
    @ObservationIgnored private var priorityPath: String?
    @ObservationIgnored private var highlighting: Task<Void, Never>?

    static let scoringConcurrency = 4
    @ObservationIgnored private var blocks: [String: [DiffBlock]] = [:]
    /// Per file, one score per block. Applied to rows, never written into `diff`.
    @ObservationIgnored private var scores: [String: [BlockScore?]] = [:]
    /// Outlives reloads, so a push only pays for the blocks it changed.
    @ObservationIgnored private var cache: [BlockKey: BlockScore] = [:]
    @ObservationIgnored private var pendingScores: [String] = []
    @ObservationIgnored private var scoring: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(
        repo: String, number: Int, source: PullRequestDiffing?, viewedWriter: PullRequestDiffing?,
        highlighter: SyntaxHighlighting? = nil, scorer: BlockScoring? = nil,
        scoringRetryDelay: Duration = .seconds(2), preferences: PreferenceStoring = UserDefaultsPreferences()
    ) {
        self.repo = repo
        self.number = number
        self.source = source
        self.viewedWriter = viewedWriter
        self.highlighter = highlighter
        self.scorer = scorer
        self.scoringRetryDelay = scoringRetryDelay
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
            prepareScoring()
            rebuildRows()
            phase = .loaded
            evaluateLiveState()
            startHighlighting()
            startScoring()
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

    /// The file on screen, so it is coloured and scored before the rest.
    public func prioritise(_ path: String) {
        priorityPath = path
        if let index = pendingHighlights.firstIndex(of: path) {
            pendingHighlights.insert(pendingHighlights.remove(at: index), at: 0)
        }
        if let index = pendingScores.firstIndex(of: path) {
            pendingScores.insert(pendingScores.remove(at: index), at: 0)
        }
    }

    /// Off keeps every score already paid for, so on again shows them at once.
    public func setHeatmapEnabled(_ enabled: Bool) {
        guard enabled != heatmapEnabled else { return }
        heatmapEnabled = enabled
        rebuildRows()
        startScoring()
    }

    public func requestScoring() {
        guard canRequestScoring else { return }
        scoringRequested = true
        rebuildRows()
        startScoring()
    }

    func scoringFinished() async {
        while let task = scoring {
            await task.value
            if task == scoring { return }
        }
    }

    private func prepareScoring() {
        generation += 1
        guard scorer != nil else { return }
        let files = diff?.files ?? []
        blocks = Dictionary(files.map { ($0.path, DiffBlocks.blocks(in: $0)) }.filter { !$0.1.isEmpty },
                            uniquingKeysWith: { $1 })
        scores = [:]
        heat = [:]
        scoringStopped = nil
        for (path, fileBlocks) in blocks {
            let cached = fileBlocks.map { cache[$0.key] }
            if cached.allSatisfy({ $0 != nil }) {
                scores[path] = cached
                heat[path] = .scored(Self.hottest(cached))
            } else {
                heat[path] = .waiting
            }
        }
    }

    private func startScoring() {
        scoring?.cancel()
        scoring = nil
        guard let scorer, heatmapEnabled, scoringRequested else { return }
        pendingScores = groups.flatMap(\.files).map(\.path).filter { heat[$0] == .waiting }
        if let priorityPath { prioritise(priorityPath) }
        let generation = generation
        // Weak between files, so closing the window stops the work after the files in flight.
        scoring = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.scoringConcurrency {
                    group.addTask {
                        while !Task.isCancelled, await self?.scoreNextFile(scorer, generation: generation) == true {}
                    }
                }
            }
        }
    }

    private func scoreNextFile(_ scorer: BlockScoring, generation: Int) async -> Bool {
        guard !pendingScores.isEmpty else { return false }
        let path = pendingScores.removeFirst()
        guard let fileBlocks = blocks[path] else { return true }
        let result: BlockScores
        do {
            result = try await score(path, fileBlocks, with: scorer)
        } catch {
            guard !Task.isCancelled, generation == self.generation else { return false }
            let message = Self.message(for: error)
            switch error as? PRMasterError {
            case .heatmapUnauthorized, .heatmapNoCredits:
                scoringStopped = message
                for pending in pendingScores + [path] { heat[pending] = .failed(message) }
                pendingScores = []
                return false
            default:
                heat[path] = .failed(message)
                return true
            }
        }
        guard !Task.isCancelled, generation == self.generation else { return false }
        for (block, score) in zip(fileBlocks, result.blocks) {
            if let score { cache[block.key] = score }
        }
        scores[path] = result.blocks
        heat[path] = result.tooLarge ? .failed(Self.tooLargeMessage) : .scored(Self.hottest(result.blocks))
        rebuildRows()
        return true
    }

    /// Waits out a rate limit as long as asked, and gives a stumbling provider one more try.
    private func score(_ path: String, _ blocks: [DiffBlock], with scorer: BlockScoring) async throws -> BlockScores {
        var retried = false
        while true {
            do {
                return try await scorer.score(path: path, blocks: blocks)
            } catch PRMasterError.rateLimited(let until) {
                try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            } catch PRMasterError.heatmapUnavailable where !retried {
                retried = true
                try await Task.sleep(for: scoringRetryDelay)
            }
        }
    }

    private static func hottest(_ scores: [BlockScore?]) -> Importance? {
        scores.compactMap { $0?.level }.max()
    }

    private func scored(_ file: DiffFile) -> DiffFile {
        guard showsHeat, let fileScores = scores[file.path], let fileBlocks = blocks[file.path],
              case .hunks(var hunks) = file.content
        else { return file }
        var lines = hunks.map(\.lines)
        for (block, score) in zip(fileBlocks, fileScores) where lines.indices.contains(block.hunk) {
            for (offset, index) in block.lines.enumerated() where lines[block.hunk].indices.contains(index) {
                lines[block.hunk][index].heat = score?.heat(ofLine: offset)
            }
        }
        for index in hunks.indices { hunks[index] = hunks[index].with(lines: lines[index]) }
        return file.with(content: .hunks(hunks))
    }

    func highlightingFinished() async {
        while let task = highlighting {
            await task.value
            if task == highlighting { return }
        }
    }

    private func startHighlighting() {
        highlighting?.cancel()
        guard highlighter != nil, diff != nil else { return }
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
        let files = (diff?.files ?? []).map(scored)
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
