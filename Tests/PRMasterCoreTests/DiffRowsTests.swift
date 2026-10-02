import Foundation
import Testing
@testable import PRMasterCore

private func hunk(_ patch: String) throws -> Hunk {
    try #require(PatchParser.hunks(patch).first)
}

private func file(_ path: String, _ content: DiffContent) -> DiffFile {
    DiffFile(path: path, previousPath: nil, change: .modified, additions: 0, deletions: 0, content: content)
}

private func pairs(_ rows: [DiffRow]) -> [(left: String?, right: String?)] {
    rows.compactMap {
        guard case .pair(let left, let right) = $0 else { return nil }
        return (left?.text, right?.text)
    }
}

@Suite("DiffRows")
struct DiffRowsTests {

    @Test("three removed against one added pair the first and leave the right side blank for the rest")
    func unevenChange() throws {
        let rows = DiffRows.split(try hunk("@@ -1,3 +1 @@\n-a\n-b\n-c\n+x"))
        let texts = pairs(rows)
        #expect(texts.map(\.left) == ["a", "b", "c"])
        #expect(texts.map(\.right) == ["x", nil, nil])
    }

    /// GitHub leaves the other side empty for a pure addition or removal. What
    /// must never happen is a row with nothing on either side, or a line moved
    /// to the side it does not belong to.
    @Test(
        "a pure addition or removal sits on its own side, with no empty rows",
        arguments: [("@@ -0,0 +1,2 @@\n+a\n+b", false), ("@@ -1,2 +0,0 @@\n-a\n-b", true)]
    )
    func oneSided(patch: String, isRemoval: Bool) throws {
        let texts = pairs(DiffRows.split(try hunk(patch)))
        #expect(texts.count == 2)
        #expect(texts.allSatisfy { ($0.left == nil) != ($0.right == nil) })
        #expect(texts.allSatisfy { ($0.left != nil) == isRemoval })
    }

    @Test("a context line appears on both sides of the same row")
    func contextPairs() throws {
        let texts = pairs(DiffRows.split(try hunk("@@ -1,2 +1,2 @@\n a\n-b\n+c")))
        #expect(texts.map(\.left) == ["a", "b"])
        #expect(texts.map(\.right) == ["a", "c"])
    }

    @Test("context closes a change block, so the next change pairs on its own")
    func blocksDoNotBleed() throws {
        let texts = pairs(DiffRows.split(try hunk("@@ -1,3 +1,3 @@\n-a\n k\n-b\n+c\n+d")))
        #expect(texts.map(\.left) == ["a", "k", "b", nil])
        #expect(texts.map(\.right) == [nil, "k", "c", "d"])
    }

    @Test("unified layout is the file header, the hunk header, then every line in order")
    func unifiedOrder() throws {
        let content = DiffContent.hunks([try hunk("@@ -1,2 +1,2 @@ func f() {\n a\n-b\n+c")])
        let rows = DiffRows.build([file("a.swift", content)], layout: .unified, collapsed: [])
        guard rows.count == 5,
              case .fileHeader(path: "a.swift") = rows[0],
              case .hunkHeader(let header) = rows[1],
              case .line(let first) = rows[2], case .line(let second) = rows[3], case .line(let third) = rows[4]
        else {
            Issue.record("unexpected rows: \(rows)")
            return
        }
        #expect(header == "@@ -1,2 +1,2 @@ func f() {")
        #expect([first, second, third].map(\.text) == ["a", "b", "c"])
    }

    @Test("split layout keeps the headers and pairs the lines")
    func splitLayout() throws {
        let content = DiffContent.hunks([try hunk("@@ -1 +1 @@\n-b\n+c")])
        let rows = DiffRows.build([file("a.swift", content)], layout: .split, collapsed: [])
        #expect(rows.count == 3)
        #expect(pairs(rows).map(\.left) == ["b"])
    }

    @Test("a collapsed file is only its header")
    func collapsed() throws {
        let content = DiffContent.hunks([try hunk("@@ -1 +1 @@\n-b\n+c")])
        let rows = DiffRows.build(
            [file("a.swift", content), file("b.swift", content)], layout: .unified, collapsed: ["a.swift"]
        )
        #expect(rows.first == .fileHeader(path: "a.swift"))
        #expect(rows[1] == .fileHeader(path: "b.swift"))
    }

    @Test("an omitted file is its header and one notice saying why")
    func omitted() {
        let rows = DiffRows.build([file("a.png", .omitted(.noTextChanges))], layout: .split, collapsed: [])
        #expect(rows == [.fileHeader(path: "a.png"), .omitted(.noTextChanges)])
    }

    @Test("no files, no rows")
    func empty() {
        #expect(DiffRows.build([], layout: .unified, collapsed: []).isEmpty)
    }

    @Test("a file's header row is where the sidebar jumps to")
    func fileIndex() throws {
        let content = DiffContent.hunks([try hunk("@@ -1 +1 @@\n-b\n+c")])
        let rows = DiffRows.build([file("a.swift", content), file("b.swift", content)], layout: .unified, collapsed: [])
        #expect(DiffRows.index(ofFile: "b.swift", in: rows) == 4)
        #expect(DiffRows.index(ofFile: "missing", in: rows) == nil)
    }

    /// The pinned header names the file the reader is inside, so a hunk or line
    /// row resolves to the header above it, never to the next file's.
    @Test("any row belongs to the file header above it")
    func owningHeader() throws {
        let content = DiffContent.hunks([try hunk("@@ -1 +1 @@\n-b\n+c")])
        let rows = DiffRows.build([file("a.swift", content), file("b.swift", content)], layout: .unified, collapsed: [])
        #expect((0...3).map { DiffRows.fileHeaderIndex(owning: $0, in: rows) } == [0, 0, 0, 0])
        #expect((4...7).map { DiffRows.fileHeaderIndex(owning: $0, in: rows) } == [4, 4, 4, 4])
        #expect(DiffRows.fileHeaderIndex(owning: 99, in: rows) == nil)
        #expect(DiffRows.fileHeaderIndex(owning: 0, in: []) == nil)
    }

    @Test("the next file header after a row is where the pinned header gets pushed away")
    func nextHeader() throws {
        let content = DiffContent.hunks([try hunk("@@ -1 +1 @@\n-b\n+c")])
        let rows = DiffRows.build([file("a.swift", content), file("b.swift", .omitted(.tooLarge))], layout: .unified, collapsed: [])
        #expect(DiffRows.nextFileHeaderIndex(after: 0, in: rows) == 4)
        #expect(DiffRows.nextFileHeaderIndex(after: 4, in: rows) == nil)
    }

    @Test("copying unified rows gives the code with its markers, headers as they read")
    func copyUnified() throws {
        let content = DiffContent.hunks([try hunk("@@ -1,2 +1,2 @@\n a\n-b\n+c")])
        let rows = DiffRows.build([file("a.swift", content)], layout: .unified, collapsed: [])
        #expect(DiffRows.copyText(rows) == "a.swift\n@@ -1,2 +1,2 @@\n a\n-b\n+c")
    }

    @Test("copying split rows gives the new side, falling back to the old where the new is blank")
    func copySplit() throws {
        let rows = DiffRows.split(try hunk("@@ -1,2 +1 @@\n-a\n-b\n+x"))
        #expect(DiffRows.copyText(Array(rows.dropFirst())) == "x\nb")
    }

    @Test("colour arriving on the same text wraps the same, so the table need not rewrap", arguments: DiffLayout.allCases)
    func coloursKeepWrapping(layout: DiffLayout) throws {
        let plain = file("a.swift", .hunks([try hunk("@@ -1,2 +1,2 @@\n a\n-let b\n+let c")]))
        var coloured = plain
        guard case .hunks(var hunks) = plain.content else { return }
        var lines = hunks[0].lines
        for index in lines.indices { lines[index].tokens = [TokenRange(location: 0, length: 1, colour: .hex(0xCF222E))] }
        hunks[0] = Hunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, context: "", lines: lines)
        coloured = DiffFile(path: plain.path, previousPath: nil, change: .modified, additions: 0, deletions: 0,
                            content: .hunks(hunks))

        let before = DiffRows.build([plain], layout: layout, collapsed: [])
        let after = DiffRows.build([coloured], layout: layout, collapsed: [])
        #expect(before != after)
        #expect(DiffRows.wrapTheSame(before, after))
    }

    @Test("changed text, a collapsed file or a different path needs a rewrap")
    func textChangesNeedRewrap() throws {
        let one = file("a.swift", .hunks([try hunk("@@ -1 +1 @@\n-let b\n+let c")]))
        let other = file("a.swift", .hunks([try hunk("@@ -1 +1 @@\n-let b\n+let longer")]))
        let rows = DiffRows.build([one], layout: .unified, collapsed: [])
        #expect(!DiffRows.wrapTheSame(rows, DiffRows.build([other], layout: .unified, collapsed: [])))
        #expect(!DiffRows.wrapTheSame(rows, DiffRows.build([one], layout: .unified, collapsed: ["a.swift"])))
        #expect(!DiffRows.wrapTheSame(rows, DiffRows.build([file("b.swift", one.content)], layout: .unified, collapsed: [])))
        #expect(!DiffRows.wrapTheSame(rows, DiffRows.build([one], layout: .split, collapsed: [])))
    }

    // MARK: - Sections

    private func sectioned() throws -> [DiffRow] {
        let content = DiffContent.hunks([try hunk("@@ -1 +1 @@\n-b\n+c")])
        return DiffRows.build(
            groups: [
                DiffFileGroup(section: .other, files: [file("CLAUDE.md", content)]),
                DiffFileGroup(section: .tests, files: [file("a_test.go", content), file("b_test.go", content)]),
                DiffFileGroup(section: .generated, files: []),
                DiffFileGroup(section: .review, files: [file("a.go", content)]),
            ],
            layout: .unified, isCollapsed: { $0 != "a.go" }
        )
    }

    @Test("review files come first, then each non-empty set-aside group behind its own divider")
    func sectionOrder() throws {
        let rows = try sectioned()
        #expect(rows.count == 9)
        #expect(rows[0] == .fileHeader(path: "a.go"))
        #expect(rows[4] == .section(.tests, count: 2))
        #expect(rows[5] == .fileHeader(path: "a_test.go"))
        #expect(rows[6] == .fileHeader(path: "b_test.go"))
        #expect(rows[7] == .section(.other, count: 1))
        #expect(rows[8] == .fileHeader(path: "CLAUDE.md"))
        #expect(!rows.contains(.section(.generated, count: 0)))
    }

    @Test("with no review files the diff opens on the first divider")
    func noReviewFiles() {
        let rows = DiffRows.build(
            groups: [DiffFileGroup(section: .tests, files: [file("a_test.go", .omitted(.tooLarge))])],
            layout: .unified, isCollapsed: { _ in true }
        )
        #expect(rows == [.section(.tests, count: 1), .fileHeader(path: "a_test.go")])
    }

    /// A divider is not part of the file above it, so the pinned header must not
    /// name that file over the divider, and the divider pushes it away.
    @Test("a divider ends the file above it for the pinned header")
    func dividerEndsFile() throws {
        let rows = try sectioned()
        #expect(DiffRows.fileHeaderIndex(owning: 3, in: rows) == 0)
        #expect(DiffRows.fileHeaderIndex(owning: 4, in: rows) == nil)
        #expect(DiffRows.fileHeaderIndex(owning: 5, in: rows) == 5)
        #expect(DiffRows.nextFileHeaderIndex(after: 0, in: rows) == 4)
        #expect(DiffRows.index(ofFile: "CLAUDE.md", in: rows) == 8)
    }

    @Test("dividers carry no text to find or copy")
    func dividerHasNoText() throws {
        let rows = try sectioned()
        #expect(DiffRows.text(of: .section(.tests, count: 2), column: 0) == nil)
        #expect(DiffSearch.matches(of: "tests", in: [.section(.tests, count: 2)]).isEmpty)
        #expect(DiffRows.copyText(Array(rows[3...5])) == "+c\na_test.go")
    }
}

/// Marks are where a reviewer jumps to, so they must point at the important
/// changes and nothing else.
@Suite("Heat marks")
struct HeatMarksTests {

    private func line(_ level: Importance?, kind: DiffLine.Kind = .added) -> DiffRow {
        var line = DiffLine(kind: kind, oldNumber: nil, newNumber: 1, text: "x")
        line.heat = level.map { LineHeat(score: Double($0.rawValue), confidence: 0.9) }
        return .line(line)
    }

    @Test("a run of business logic or sensitive rows is one mark at its first row, at its highest level")
    func runs() {
        let rows: [DiffRow] = [
            .fileHeader(path: "a"), line(.glue), line(.logic), line(.sensitive), line(nil, kind: .context),
            line(.routine), line(.logic), .fileHeader(path: "b"), line(.sensitive), line(.sensitive),
        ]
        #expect(DiffRows.heatMarks(rows) == [
            HeatMark(row: 2, fraction: 0.2, level: .sensitive),
            HeatMark(row: 6, fraction: 0.6, level: .logic),
            HeatMark(row: 8, fraction: 0.8, level: .sensitive),
        ])
    }

    @Test("glue and routine are not worth a jump")
    func quietRowsUnmarked() {
        #expect(DiffRows.heatMarks([line(.glue), line(.routine), line(nil)]).isEmpty)
    }

    @Test("an empty table has no marks")
    func empty() {
        #expect(DiffRows.heatMarks([]).isEmpty)
    }

    @Test("a split row counts the more important of its two sides")
    func splitPairs() {
        var left = DiffLine(kind: .removed, oldNumber: 1, newNumber: nil, text: "x")
        left.heat = LineHeat(score: 1, confidence: 0.9)
        var right = DiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "y")
        right.heat = LineHeat(score: 3, confidence: 0.9)
        #expect(DiffRows.heatMarks([.pair(left: left, right: right)]) == [HeatMark(row: 0, fraction: 0, level: .sensitive)])
    }
}
