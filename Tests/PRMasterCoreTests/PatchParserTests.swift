import Foundation
import Testing
@testable import PRMasterCore

/// Shaped like the first hunk of `internal/attachments/client.go` in
/// cli/cli#14516. Built from an array because a blank context line is a lone
/// space, which a multi-line literal would make invisible.
private let realHunk = [
    "@@ -68,11 +68,13 @@ func checkHost(host string) error {",
    " \treturn nil",
    " }",
    " ",
    "-// uploadTokenTypes lists the credentials that can attach a file.",
    "+// uploadTokenTypes lists the credentials that can attach files.",
    "+// App user-to-server tokens are accepted for supported actors.",
    " var uploadTokenTypes = map[string]bool{",
    " \t\"gho_\": true,",
    " \t\"ghp_\": true,",
    "+\t\"ghu_\": true,",
    " \t\"github_pat_\": true,",
    " }",
    " ",
    " func newUploader() {",
].joined(separator: "\n")

@Suite("PatchParser")
struct PatchParserTests {

    @Test("a hunk header gives both starting lines, both counts and the function context")
    func header() throws {
        let hunk = try #require(PatchParser.hunks(realHunk).first)
        #expect(hunk.oldStart == 68)
        #expect(hunk.oldCount == 11)
        #expect(hunk.newStart == 68)
        #expect(hunk.newCount == 13)
        #expect(hunk.context == "func checkHost(host string) error {")
    }

    @Test("an omitted count means one line, as in git's own output")
    func omittedCount() throws {
        let hunk = try #require(PatchParser.hunks("@@ -3 +3 @@\n-old\n+new").first)
        #expect(hunk.oldCount == 1)
        #expect(hunk.newCount == 1)
        #expect(hunk.context == "")
    }

    /// A wrong number here puts every review comment a reader writes down on
    /// the wrong line, so it is checked on both sides at every step.
    @Test("line numbers advance on the side each line belongs to")
    func numbering() throws {
        let lines = try #require(PatchParser.hunks(realHunk).first).lines
        let numbers = lines.map { [$0.oldNumber, $0.newNumber] }
        #expect(numbers == [
            [68, 68], [69, 69], [70, 70],
            [71, nil],
            [nil, 71], [nil, 72],
            [72, 73], [73, 74], [74, 75],
            [nil, 76],
            [75, 77], [76, 78], [77, 79], [78, 80],
        ])
    }

    @Test("numbering restarts from each hunk's own header")
    func multipleHunks() throws {
        let patch = """
        @@ -1,2 +1,2 @@
        -a
        +b
         c
        @@ -40,2 +40,3 @@ struct Widget {
         d
        +e
         f
        """
        let hunks = try PatchParser.hunks(patch)
        #expect(hunks.count == 2)
        #expect(hunks[1].lines.map(\.oldNumber) == [40, nil, 41])
        #expect(hunks[1].lines.map(\.newNumber) == [40, 41, 42])
    }

    @Test("each line keeps its kind and its text without the prefix")
    func kindsAndText() throws {
        let lines = try #require(PatchParser.hunks("@@ -1,2 +1,2 @@\n keep\n-gone\n+here").first).lines
        #expect(lines.map(\.kind) == [.context, .removed, .added])
        #expect(lines.map(\.text) == ["keep", "gone", "here"])
    }

    @Test("the no-newline marker flags the line before it and is not a line itself")
    func noNewlineMarker() throws {
        let patch = "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file"
        let lines = try #require(PatchParser.hunks(patch).first).lines
        #expect(lines.count == 2)
        #expect(lines.map(\.noNewlineAtEnd) == [true, true])
    }

    @Test("only the line before the marker is flagged")
    func markerIsLocal() throws {
        let patch = "@@ -1,2 +1,2 @@\n a\n-old\n\\ No newline at end of file\n+new"
        let lines = try #require(PatchParser.hunks(patch).first).lines
        #expect(lines.map(\.noNewlineAtEnd) == [false, true, false])
    }

    @Test("a carriage return from a Windows file is not drawn as part of the line")
    func carriageReturn() throws {
        let lines = try #require(PatchParser.hunks("@@ -1 +1 @@\r\n-old\r\n+new\r").first).lines
        #expect(lines.map(\.text) == ["old", "new"])
    }

    @Test("a line opening with a combining mark does not swallow its prefix")
    func combiningMark() throws {
        let lines = try #require(PatchParser.hunks("@@ -1 +1 @@\n-a\n+\u{301}b").first).lines
        #expect(lines.map(\.kind) == [.removed, .added])
        #expect(lines[1].text == "\u{301}b")
    }

    @Test("an empty context line still counts towards the hunk")
    func emptyContextLine() throws {
        let lines = try #require(PatchParser.hunks("@@ -1,3 +1,3 @@\n a\n\n-b\n+c").first).lines
        #expect(lines.map(\.kind) == [.context, .context, .removed, .added])
        #expect(lines[1].text == "")
    }

    @Test("a trailing newline after the last hunk is not read as one more line")
    func trailingNewline() throws {
        let lines = try #require(PatchParser.hunks("@@ -1 +1 @@\n-a\n+b\n").first).lines
        #expect(lines.count == 2)
    }

    @Test("an empty patch has no hunks")
    func emptyPatch() throws {
        #expect(try PatchParser.hunks("").isEmpty)
    }

    @Test(
        "a patch that cannot be numbered correctly is refused rather than drawn",
        arguments: [
            "@@ -x,1 +1 @@\n-a\n+b",
            "@@ -1 +1\n-a\n+b",
            "not a header\n-a",
            "@@ -1,3 +1,3 @@\n a\n-b",
            "@@ -1 +1 @@\n-a\n+b\n+c",
            "@@ -1 +1 @@\n?a\n+b",
        ]
    )
    func malformed(patch: String) {
        #expect(throws: PatchError.self) { try PatchParser.hunks(patch) }
    }
}
