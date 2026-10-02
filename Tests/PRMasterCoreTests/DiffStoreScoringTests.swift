import Foundation
import Testing
@testable import PRMasterCore

private final class ChangingDiffSource: PullRequestDiffing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PullRequestDiff

    init(_ diff: PullRequestDiff) { current = diff }

    var diff: PullRequestDiff {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func loadDiff(repo: String, number: Int) async throws -> PullRequestDiff { diff }
    func setViewed(pullRequestID: String, path: String, viewed: Bool) async throws {}
}

/// Scores a block sensitive when its text says "danger", glue otherwise, behind a gate.
private actor GatedScorer: BlockScoring {
    private var isOpen: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var inFlight = 0
    private(set) var asked: [String] = []
    private(set) var maxInFlight = 0

    init(open: Bool = true) { isOpen = open }

    func score(path: String, blocks: [DiffBlock]) async throws -> BlockScores {
        asked.append(path)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        inFlight -= 1
        return BlockScores(levels: blocks.map { $0.key.text.contains("danger") ? .sensitive : .glue }, tooLarge: false)
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func waitUntilAsked(_ count: Int) async {
        while asked.count < count { await Task.yield() }
    }
}

private func file(_ path: String, text: String = "let a") -> DiffFile {
    DiffFile(
        path: path, previousPath: nil, change: .modified, additions: 1, deletions: 1,
        content: .hunks([Hunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, context: "",
            lines: [DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "import Foundation"),
                    DiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "old"),
                    DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: text)]
        )])
    )
}

private func diff(_ files: [DiffFile]) -> PullRequestDiff {
    PullRequestDiff(pullRequestID: "PR_1", baseOid: "B1", headOid: "H1", files: files, isTruncated: false)
}

@MainActor
private func store(
    _ source: ChangingDiffSource, scorer: BlockScoring?, highlighter: SyntaxHighlighting? = nil
) -> DiffStore {
    DiffStore(repo: "acme/widget", number: 7, source: source, viewedWriter: source,
              highlighter: highlighter, scorer: scorer, preferences: MemoryPreferences())
}

@MainActor
private func importances(_ store: DiffStore) -> [DiffLine.Kind: Set<Importance?>] {
    var found: [DiffLine.Kind: Set<Importance?>] = [:]
    for row in store.rows {
        let lines: [DiffLine]
        switch row {
        case .line(let line): lines = [line]
        case .pair(let left, let right): lines = [left, right].compactMap { $0 }
        default: lines = []
        }
        for line in lines { found[line.kind, default: []].insert(line.heat?.level) }
    }
    return found
}

/// Scores arrive over the network while the reviewer reads. Every test here
/// guards one way the stripes could lie: stale, missing, lost to a highlight,
/// or bought twice.
@MainActor
@Suite("DiffStore scoring")
struct DiffStoreScoringTests {

    @Test("the file on screen is scored before the ones above it")
    func prioritised() async {
        let scorer = GatedScorer(open: false)
        let source = ChangingDiffSource(diff(["a", "b", "c", "d", "e"].map { file("\($0).swift") }))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        store.prioritise("e.swift")
        await scorer.waitUntilAsked(4)
        #expect(Set(await scorer.asked) == ["e.swift", "a.swift", "b.swift", "c.swift"])
        await scorer.open()
        await store.scoringFinished()
    }

    @Test("no more than four files are in flight at once")
    func concurrency() async {
        let scorer = GatedScorer(open: false)
        let source = ChangingDiffSource(diff((0..<10).map { file("f\($0).swift") }))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        await scorer.waitUntilAsked(4)
        for _ in 0..<200 { await Task.yield() }
        #expect(await scorer.asked.count == 4)
        await scorer.open()
        await store.scoringFinished()
        #expect(await scorer.asked.count == 10)
        #expect(await scorer.maxInFlight == 4)
    }

    @Test("changed lines carry their block's level in both layouts, unchanged lines none")
    func rowsCarryImportance() async {
        let source = ChangingDiffSource(diff([file("a.swift", text: "danger()")]))
        let store = store(source, scorer: GatedScorer())
        await store.load()
        store.requestScoring()
        #expect(importances(store)[.added] == [nil])
        await store.scoringFinished()
        #expect(importances(store)[.added] == [.sensitive])
        #expect(importances(store)[.removed] == [.sensitive])
        #expect(importances(store)[.context] == [nil])
        #expect(store.heat["a.swift"] == .scored(.sensitive))
        store.layout = .split
        #expect(importances(store)[.added] == [.sensitive])
        #expect(importances(store)[.context] == [nil])
    }

    @Test("each changed line shows its own answer; a line without one shows its block's")
    func perLineHeat() async throws {
        let patch = "@@ -1,2 +1,3 @@\n-old()\n+guard user.isAdmin else { return }\n+}\n keep"
        let twoLines = DiffFile(path: "a.swift", previousPath: nil, change: .modified, additions: 2, deletions: 1,
                                content: .hunks(try PatchParser.hunks(patch)))
        let score = BlockScore(block: LineHeat(score: 1.2, confidence: 0.7),
                               lines: [LineHeat(score: 0.2, confidence: 0.9), LineHeat(score: 2.8, confidence: 0.3), nil])
        let scorer = ScriptedScorer(["a.swift": [.success(BlockScores(blocks: [score], tooLarge: false))]])
        let source = ChangingDiffSource(diff([twoLines]))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        let heats = store.rows.compactMap { row -> LineHeat? in
            guard case .line(let line) = row, line.kind != .context else { return nil }
            return line.heat
        }
        #expect(heats == [score.heat(ofLine: 0), score.heat(ofLine: 1), score.block])
        #expect(heats[1].isUncertain)
        #expect(store.heat["a.swift"] == .scored(.sensitive))
    }

    @Test("a highlight finishing after a score keeps the score")
    func highlightingKeepsScores() async {
        let source = ChangingDiffSource(diff([file("a.swift", text: "danger()")]))
        let store = store(source, scorer: GatedScorer(), highlighter: ShikiScript.highlighter)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        await store.highlightingFinished()
        #expect(importances(store)[.added] == [.sensitive])
        #expect(store.rows.contains {
            guard case .line(let line) = $0 else { return false }
            return !line.tokens.isEmpty && line.heat?.level == .sensitive
        })
    }

    @Test("an answer for a diff that was reloaded meanwhile is dropped")
    func staleAnswersDropped() async {
        let scorer = GatedScorer(open: false)
        let source = ChangingDiffSource(diff([file("a.swift", text: "danger()")]))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        await scorer.waitUntilAsked(1)
        source.diff = diff([file("a.swift", text: "label()")])
        await store.load()
        store.requestScoring()
        await scorer.open()
        await store.scoringFinished()
        #expect(importances(store)[.added] == [.glue])
        #expect(store.heat["a.swift"] == .scored(.glue))
    }

    @Test("reloading the same commit sends nothing: every block's score is remembered")
    func unchangedReloadIsFree() async {
        let scorer = GatedScorer()
        let source = ChangingDiffSource(diff([file("a.swift", text: "danger()"), file("b.swift")]))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(await scorer.asked.count == 2)
        await store.load()
        store.requestScoring()
        #expect(importances(store)[.added] == [.sensitive, .glue])
        await store.scoringFinished()
        #expect(await scorer.asked.count == 2)
    }

    @Test("after a push only the file that changed is sent again")
    func onlyChangedBlocksSent() async {
        let scorer = GatedScorer()
        let source = ChangingDiffSource(diff([file("a.swift"), file("b.swift")]))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        source.diff = diff([file("a.swift"), file("b.swift", text: "danger()")])
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(await scorer.asked.sorted() == ["a.swift", "b.swift", "b.swift"])
        #expect(store.heat["b.swift"] == .scored(.sensitive))
    }

    @Test("set-aside files are scored after the files to review")
    func setAsideLast() async {
        let scorer = GatedScorer(open: false)
        let tests = (1...4).map { file("t\($0)_test.go") }
        let source = ChangingDiffSource(diff(tests + [file("a.go")]))
        let store = store(source, scorer: scorer)
        store.setScope(FileScope(patterns: [.tests: ["*_test.go"]]))
        await store.load()
        store.requestScoring()
        await scorer.waitUntilAsked(4)
        #expect(await scorer.asked.contains("a.go"))
        await scorer.open()
        await store.scoringFinished()
        #expect(await scorer.asked.count == 5)
    }

    @Test("turning the heatmap off clears the stripes; turning it back on restores them without asking again")
    func toggle() async {
        let scorer = GatedScorer()
        let source = ChangingDiffSource(diff([file("a.swift", text: "danger()")]))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        store.setHeatmapEnabled(false)
        #expect(!store.showsHeat)
        #expect(importances(store)[.added] == [nil])
        store.setHeatmapEnabled(true)
        #expect(store.showsHeat)
        #expect(importances(store)[.added] == [.sensitive])
        await store.scoringFinished()
        #expect(await scorer.asked.count == 1)
    }

    @Test("turning the heatmap off mid-scoring stops the queue; the rest waits until it is back on")
    func toggleMidway() async {
        let scorer = GatedScorer(open: false)
        let source = ChangingDiffSource(diff((0..<6).map { file("f\($0).swift") }))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        await scorer.waitUntilAsked(4)
        store.setHeatmapEnabled(false)
        await scorer.open()
        await store.scoringFinished()
        #expect(await scorer.asked.count == 4)
        #expect(importances(store)[.added] == [nil])
        store.setHeatmapEnabled(true)
        await store.scoringFinished()
        #expect(importances(store)[.added] == [.glue])
    }

    @Test("opening a review sends nothing until the reviewer asks")
    func nothingUntilAsked() async {
        let scorer = GatedScorer()
        let source = ChangingDiffSource(diff([file("a.swift", text: "danger()")]))
        let store = store(source, scorer: scorer)
        await store.load()
        await store.scoringFinished()
        #expect(await scorer.asked.isEmpty)
        #expect(store.canRequestScoring)
        #expect(!store.showsHeat)
        #expect(importances(store)[.added] == [nil])
    }

    @Test("asking scores the review, and hides the button")
    func askingScores() async {
        let scorer = GatedScorer()
        let source = ChangingDiffSource(diff([file("a.swift", text: "danger()"), file("b.swift")]))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        #expect(!store.canRequestScoring)
        #expect(store.showsHeat)
        await store.scoringFinished()
        #expect(await scorer.asked.count == 2)
        #expect(importances(store)[.added] == [.sensitive, .glue])
    }

    @Test("once asked, a reload after a push scores the changes without asking again")
    func reloadAfterAsking() async {
        let scorer = GatedScorer()
        let source = ChangingDiffSource(diff([file("a.swift")]))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        source.diff = diff([file("a.swift", text: "danger()")])
        await store.load()
        await store.scoringFinished()
        #expect(await scorer.asked.count == 2)
        #expect(importances(store)[.added] == [.sensitive])
    }

    @Test("asking is only offered with a scorer and the switch on")
    func buttonAvailability() async {
        let source = ChangingDiffSource(diff([file("a.swift")]))
        let without = store(source, scorer: nil)
        await without.load()
        #expect(!without.canRequestScoring)
        let with = store(source, scorer: GatedScorer())
        await with.load()
        with.setHeatmapEnabled(false)
        #expect(!with.canRequestScoring)
        with.setHeatmapEnabled(true)
        #expect(with.canRequestScoring)
    }

    @Test("turning the switch back on before asking still sends nothing")
    func toggleBeforeAsking() async {
        let scorer = GatedScorer()
        let source = ChangingDiffSource(diff([file("a.swift")]))
        let store = store(source, scorer: scorer)
        await store.load()
        store.setHeatmapEnabled(false)
        store.setHeatmapEnabled(true)
        await store.scoringFinished()
        #expect(await scorer.asked.isEmpty)
    }

    @Test("without a scorer nothing is scored and no file waits")
    func noScorer() async {
        let source = ChangingDiffSource(diff([file("a.swift")]))
        let store = store(source, scorer: nil)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(!store.showsHeat)
        #expect(store.heat.isEmpty)
        #expect(importances(store)[.added] == [nil])
    }

    @Test("a file with no changed text is not queued")
    func omittedNotQueued() async {
        let scorer = GatedScorer()
        let image = DiffFile(path: "logo.png", previousPath: nil, change: .added, additions: 0, deletions: 0,
                             content: .omitted(.noTextChanges))
        let source = ChangingDiffSource(diff([image, file("a.swift")]))
        let store = store(source, scorer: scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(await scorer.asked == ["a.swift"])
        #expect(store.heat["logo.png"] == nil)
    }
}

/// Answers each path from a script, then glue once the script runs out.
private actor ScriptedScorer: BlockScoring {
    private var script: [String: [Result<BlockScores?, PRMasterError>]]
    private(set) var asked: [String] = []

    init(_ script: [String: [Result<BlockScores?, PRMasterError>]] = [:], everyFile: PRMasterError? = nil) {
        self.script = script
        self.everyFile = everyFile
    }

    private let everyFile: PRMasterError?

    func score(path: String, blocks: [DiffBlock]) async throws -> BlockScores {
        asked.append(path)
        if let everyFile { throw everyFile }
        let next = script[path]?.isEmpty == false ? script[path]!.removeFirst() : .success(nil)
        return try next.get() ?? BlockScores(levels: blocks.map { _ in .glue }, tooLarge: false)
    }

    func count(_ path: String) -> Int { asked.filter { $0 == path }.count }
}

@MainActor
private func failureStore(_ scorer: BlockScoring, files: [DiffFile] = [file("a.swift")]) -> DiffStore {
    let source = ChangingDiffSource(diff(files))
    return DiffStore(repo: "acme/widget", number: 7, source: source, viewedWriter: source, scorer: scorer,
                     scoringRetryDelay: .milliseconds(10), preferences: MemoryPreferences())
}

/// A failure must never pass for a finished heatmap: every file ends scored or
/// failed with a reason, and a dead key or empty account stops the spending.
@MainActor
@Suite("DiffStore scoring failures")
struct DiffStoreScoringFailureTests {

    @Test("a rejected key stops the queue: no request goes out after the first refusal", arguments: [
        PRMasterError.heatmapUnauthorized, .heatmapNoCredits,
    ])
    func stopsOnDeadKey(error: PRMasterError) async {
        let scorer = ScriptedScorer(everyFile: error)
        let store = failureStore(scorer, files: (0..<10).map { file("f\($0).swift") })
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(await scorer.asked.count <= DiffStore.scoringConcurrency)
        #expect(store.scoringStopped == error.localizedDescription)
        #expect(store.heat.values.allSatisfy { $0 == .failed(error.localizedDescription) })
        #expect(store.scoringProgress == nil)
    }

    @Test("the next load tries a stopped queue again")
    func stopClearsOnLoad() async {
        let scorer = ScriptedScorer(["a.swift": [.failure(.heatmapUnauthorized)]])
        let store = failureStore(scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(store.scoringStopped != nil)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(store.scoringStopped == nil)
        #expect(store.heat["a.swift"] == .scored(.glue))
    }

    @Test("a rate limit pauses the file until the time given, then scores it")
    func rateLimited() async {
        let scorer = ScriptedScorer(["a.swift": [.failure(.rateLimited(until: Date().addingTimeInterval(0.05)))]])
        let store = failureStore(scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(await scorer.count("a.swift") == 2)
        #expect(store.heat["a.swift"] == .scored(.glue))
    }

    @Test("a provider hiccup is retried once and then scores")
    func retriedOnce() async {
        let scorer = ScriptedScorer(["a.swift": [.failure(.heatmapUnavailable(status: 502))]])
        let store = failureStore(scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(await scorer.count("a.swift") == 2)
        #expect(store.heat["a.swift"] == .scored(.glue))
    }

    @Test("a provider failing twice fails the file and the queue moves on")
    func failsAfterRetry() async {
        let failure = PRMasterError.heatmapUnavailable(status: 502)
        let scorer = ScriptedScorer(["a.swift": [.failure(failure), .failure(failure)]])
        let store = failureStore(scorer, files: [file("a.swift"), file("b.swift")])
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(await scorer.count("a.swift") == 2)
        #expect(store.heat["a.swift"] == .failed(failure.localizedDescription))
        #expect(store.heat["b.swift"] == .scored(.glue))
        #expect(store.scoringStopped == nil)
    }

    @Test("a refused request is not retried: asking again gets the same answer")
    func refusedNotRetried() async {
        let failure = PRMasterError.heatmapRefused("HTTP 413")
        let scorer = ScriptedScorer(["a.swift": [.failure(failure)]])
        let store = failureStore(scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(await scorer.count("a.swift") == 1)
        #expect(store.heat["a.swift"] == .failed(failure.localizedDescription))
    }

    @Test("a partial answer keeps the blocks that did get a score")
    func partial() async throws {
        let patch = "@@ -1,3 +1,3 @@\n-a\n+b\n keep\n-c\n+d"
        let twoBlocks = DiffFile(path: "a.swift", previousPath: nil, change: .modified, additions: 2, deletions: 2,
                                 content: .hunks(try PatchParser.hunks(patch)))
        let scorer = ScriptedScorer(["a.swift": [.success(BlockScores(levels: [nil, .logic], tooLarge: false))]])
        let store = failureStore(scorer, files: [twoBlocks])
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        let added = store.rows.compactMap { row -> DiffLine? in
            guard case .line(let line) = row, line.kind == .added else { return nil }
            return line
        }
        #expect(added.map(\.heat?.level) == [nil, .logic])
        #expect(store.heat["a.swift"] == .scored(.logic))
    }

    @Test("a file with a block too big to send says so, and keeps the scores it has")
    func tooLarge() async {
        let scorer = ScriptedScorer(["a.swift": [.success(BlockScores(levels: [.routine], tooLarge: true))]])
        let store = failureStore(scorer)
        await store.load()
        store.requestScoring()
        await store.scoringFinished()
        #expect(store.heat["a.swift"] == .failed(DiffStore.tooLargeMessage))
        #expect(store.rows.contains {
            guard case .line(let line) = $0 else { return false }
            return line.heat?.level == .routine
        })
    }

    @Test("progress counts files until none is waiting")
    func progress() async {
        let scorer = GatedScorer(open: false)
        let source = ChangingDiffSource(diff((0..<6).map { file("f\($0).swift") }))
        let store = DiffStore(repo: "acme/widget", number: 7, source: source, viewedWriter: source, scorer: scorer,
                              preferences: MemoryPreferences())
        await store.load()
        store.requestScoring()
        #expect(store.scoringProgress == DiffStore.ScoringProgress(scored: 0, total: 6))
        await scorer.open()
        await store.scoringFinished()
        #expect(store.scoringProgress == nil)
        #expect(!store.heat.values.contains(.waiting))
    }
}
