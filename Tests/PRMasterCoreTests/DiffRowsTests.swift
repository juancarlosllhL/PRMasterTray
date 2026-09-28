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
}
