import Testing
@testable import PRMasterCore

/// Blocks are what the model scores, so their edges decide which lines share a
/// colour and their keys decide what a reload may reuse.
@Suite("Diff blocks")
struct DiffBlocksTests {

    private func file(_ patch: String, path: String = "Sources/App/Order.swift") throws -> DiffFile {
        DiffFile(path: path, previousPath: nil, change: .modified, additions: 0, deletions: 0,
                 content: .hunks(try PatchParser.hunks(patch)))
    }

    @Test("a removal and the addition that replaces it are one block, scored together")
    func replacementIsOneBlock() throws {
        let blocks = DiffBlocks.blocks(in: try file("@@ -1,3 +1,3 @@ func total()\n let a = 1\n-let b = 2\n+let b = 3\n let c = 4"))
        #expect(blocks.count == 1)
        #expect(blocks[0].lines == 1..<3)
        #expect(blocks[0].hunk == 0)
        #expect(blocks[0].changed == ["-let b = 2", "+let b = 3"])
        #expect(blocks[0].before == ["let a = 1"])
        #expect(blocks[0].after == ["let c = 4"])
        #expect(blocks[0].declaration == "func total()")
    }

    @Test("an unchanged line between two changes makes two blocks")
    func contextSplits() throws {
        let blocks = DiffBlocks.blocks(in: try file("@@ -1,3 +1,3 @@\n-a\n+A\n keep\n-b\n+B"))
        #expect(blocks.map(\.lines) == [0..<2, 3..<5])
        #expect(blocks[0].after == ["keep"])
        #expect(blocks[1].before == ["keep"])
    }

    @Test("context around a block is capped at three lines each side")
    func contextCapped() throws {
        let patch = "@@ -1,9 +1,9 @@\n c1\n c2\n c3\n c4\n-x\n+y\n d1\n d2\n d3\n d4"
        let block = try #require(DiffBlocks.blocks(in: try file(patch)).first)
        #expect(block.before == ["c2", "c3", "c4"])
        #expect(block.after == ["d1", "d2", "d3"])
    }

    @Test("a deletion with nothing added is still a block to review")
    func deletionOnly() throws {
        let blocks = DiffBlocks.blocks(in: try file("@@ -1,3 +1,1 @@\n keep\n-drop table\n-drop index"))
        #expect(blocks.count == 1)
        #expect(blocks[0].changed == ["-drop table", "-drop index"])
        #expect(blocks[0].after.isEmpty)
    }

    @Test("a change on the first line of the file has no context before it")
    func hunkAtFileStart() throws {
        let blocks = DiffBlocks.blocks(in: try file("@@ -0,0 +1,2 @@\n+import Foundation\n+let x = 1"))
        #expect(blocks.count == 1)
        #expect(blocks[0].before.isEmpty)
        #expect(blocks[0].lines == 0..<2)
    }

    @Test("blocks from several hunks carry their hunk index")
    func severalHunks() throws {
        let blocks = DiffBlocks.blocks(in: try file("@@ -1,1 +1,1 @@\n-a\n+b\n@@ -10,1 +10,1 @@\n-c\n+d"))
        #expect(blocks.map(\.hunk) == [0, 1])
    }

    @Test("a hunk of unchanged lines only has nothing to score")
    func contextOnlyHunk() throws {
        #expect(DiffBlocks.blocks(in: try file("@@ -1,2 +1,2 @@\n a\n b")).isEmpty)
    }

    @Test("a file without hunks has nothing to score")
    func omitted() {
        let file = DiffFile(path: "a.png", previousPath: nil, change: .added, additions: 0, deletions: 0,
                            content: .omitted(.noTextChanges))
        #expect(DiffBlocks.blocks(in: file).isEmpty)
    }

    @Test("the same change parsed twice has the same key, so a reload reuses its score")
    func stableKeys() throws {
        let patch = "@@ -1,1 +1,1 @@\n-a\n+b"
        #expect(DiffBlocks.blocks(in: try file(patch)).map(\.key) == DiffBlocks.blocks(in: try file(patch)).map(\.key))
    }

    @Test("the same change in another file has another key, since where code lives changes what it means")
    func keysDifferAcrossPaths() throws {
        let patch = "@@ -1,1 +1,1 @@\n-a\n+b"
        let first = DiffBlocks.blocks(in: try file(patch, path: "Auth/Token.swift"))
        let second = DiffBlocks.blocks(in: try file(patch, path: "UI/Label.swift"))
        #expect(first.map(\.key) != second.map(\.key))
    }
}
