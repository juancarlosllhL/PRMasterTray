import Foundation
import Testing
@testable import PRMasterCore

private func file(_ path: String) -> DiffFile {
    DiffFile(path: path, previousPath: nil, change: .modified, additions: 0, deletions: 0, content: .omitted(.tooLarge))
}

@Suite("DiffSearch")
struct DiffSearchTests {

    @Test("every occurrence is found, ignoring case, as UTF-16 ranges")
    func occurrences() {
        #expect(DiffSearch.ranges(of: "ab", in: "Ab xaB ab") == [0..<2, 4..<6, 7..<9])
    }

    @Test("matches never overlap")
    func noOverlap() {
        #expect(DiffSearch.ranges(of: "aa", in: "aaaa") == [0..<2, 2..<4])
    }

    @Test("an empty or blank query matches nothing")
    func emptyQuery() {
        #expect(DiffSearch.ranges(of: "", in: "abc").isEmpty)
        #expect(DiffSearch.ranges(of: "   ", in: "a   b").isEmpty)
    }

    /// Highlights are drawn on NSString ranges, so offsets after an emoji or an
    /// Ogham separator must count UTF-16 units, not characters.
    @Test("offsets after non-ASCII text count UTF-16 units")
    func utf16Offsets() {
        #expect(DiffSearch.ranges(of: "x", in: "🙂x") == [2..<3])
        #expect(DiffSearch.ranges(of: "ᚋlan", in: "githubᚗcomᚋLansweeper") == [10..<14])
    }

    @Test("the file filter keeps files whose path contains the query, in order")
    func filterFiles() {
        let files = [file("Sources/App/DiffView.swift"), file("README.md"), file("Tests/DiffViewTests.swift")]
        #expect(DiffSearch.filter(files, by: "diffview").map(\.path) == ["Sources/App/DiffView.swift", "Tests/DiffViewTests.swift"])
        #expect(DiffSearch.filter(files, by: "").count == 3)
        #expect(DiffSearch.filter(files, by: "nothing").isEmpty)
    }

    /// The sidebar shows a file's name and its directory on separate lines, so
    /// a match across the slash is highlighted on both.
    @Test("a path match splits into the directory part and the name part")
    func splitByLine() {
        let parts = DiffSearch.pathHighlights(of: "app/diff", in: "Sources/App/DiffView.swift")
        #expect(parts.directory == [8..<11])
        #expect(parts.name == [0..<4])
    }

    @Test("a file at the root has no directory highlights")
    func rootFile() {
        let parts = DiffSearch.pathHighlights(of: "read", in: "README.md")
        #expect(parts.directory.isEmpty)
        #expect(parts.name == [0..<4])
    }

    @Test("find searches code lines, not the file and hunk headers")
    func findInUnified() throws {
        let hunks = try #require(PatchParser.hunks("@@ -1,2 +1,2 @@ render\n render()\n-render(old)\n+draw()").first)
        let rows = DiffRows.build(
            [DiffFile(path: "render.swift", previousPath: nil, change: .modified, additions: 1, deletions: 1, content: .hunks([hunks]))],
            layout: .unified, collapsed: []
        )
        let matches = DiffSearch.matches(of: "render", in: rows)
        #expect(matches == [DiffMatch(row: 2, column: 0, range: 0..<6), DiffMatch(row: 3, column: 0, range: 0..<6)])
    }

    /// Split view shows a context line on both sides, and both copies are
    /// highlighted, so both count as they would in any find bar.
    @Test("in split rows the old side is column 0 and the new side column 1")
    func findInSplit() throws {
        let hunk = try #require(PatchParser.hunks("@@ -1,2 +1,2 @@\n keep x\n-x old\n+x new").first)
        let matches = DiffSearch.matches(of: "x", in: DiffRows.split(hunk))
        #expect(matches.map(\.row) == [1, 1, 2, 2])
        #expect(matches.map(\.column) == [0, 1, 0, 1])
    }

    @Test("a blank query finds nothing")
    func findBlank() throws {
        let hunk = try #require(PatchParser.hunks("@@ -1 +1 @@\n-a\n+b").first)
        #expect(DiffSearch.matches(of: " ", in: DiffRows.split(hunk)).isEmpty)
    }
}
