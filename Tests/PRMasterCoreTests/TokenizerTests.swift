import Foundation
import Testing
@testable import PRMasterCore

private func table(_ path: String) throws -> LanguageTable {
    try #require(LanguageTable.forPath(path))
}

/// The kind covering each UTF-16 offset of `line`, or nil where nothing does.
private func kinds(_ line: String, _ path: String) throws -> [TokenKind?] {
    let ranges = Tokenizer.highlight([line], table: try table(path))[0]
    return (0..<line.utf16.count).map { offset in
        ranges.first { $0.location <= offset && offset < $0.location + $0.length }?.kind
    }
}

private func kind(of word: String, in line: String, _ path: String) throws -> TokenKind? {
    let offset = try #require(line.range(of: word)).lowerBound.utf16Offset(in: line)
    return try kinds(line, path)[offset]
}

@Suite("Tokenizer")
struct TokenizerTests {

    @Test(
        "each language colours its own keywords",
        arguments: [
            ("a.swift", "let value = 1", "let"),
            ("main.go", "func main() {}", "func"),
            ("app.ts", "const x = 1", "const"),
            ("app.js", "return x", "return"),
            ("Program.cs", "public class Widget", "class"),
            ("tool.py", "def run():", "def"),
            ("data.json", "{\"on\": true}", "true"),
            ("ci.yml", "enabled: false", "false"),
            ("build.sh", "if [ -f x ]; then", "then"),
        ]
    )
    func keywords(path: String, line: String, keyword: String) throws {
        #expect(try kind(of: keyword, in: line, path) == .keyword)
    }

    @Test("a keyword spelled inside a string is part of the string")
    func keywordInString() throws {
        #expect(try kind(of: "return", in: #"let s = "return early""#, "a.swift") == .string)
    }

    @Test("a comment marker inside a string does not start a comment")
    func markerInString() throws {
        let line = #"let url = "https://github.com" // home"#
        #expect(try kind(of: "github", in: line, "a.swift") == .string)
        #expect(try kind(of: "home", in: line, "a.swift") == .comment)
    }

    @Test("an escaped quote does not end the string")
    func escapedQuote() throws {
        let line = #"let s = "say \"let\" now"; let t = 1"#
        #expect(try kind(of: "now", in: line, "a.swift") == .string)
        #expect(try kind(of: "t =", in: line, "a.swift") == nil)
    }

    @Test("a part of a longer identifier is not a keyword")
    func keywordPrefix() throws {
        #expect(try kind(of: "letter", in: "letter = 1", "a.swift") == nil)
    }

    @Test("numbers are coloured, digits inside identifiers are not")
    func numbers() throws {
        #expect(try kind(of: "42", in: "x = 42", "a.swift") == .number)
        #expect(try kind(of: "2", in: "v2 = x", "a.swift") == nil)
    }

    @Test("a hash only starts a comment where the shell would read one")
    func hashComment() throws {
        #expect(try kind(of: "note", in: "echo hi # note", "build.sh") == .comment)
        #expect(try kind(of: "#", in: "echo ${#list}", "build.sh") == nil)
    }

    @Test("a block comment carries to the next line and ends where it closes")
    func blockCommentCarries() throws {
        let ranges = Tokenizer.highlight(["let a = 1 /* open", "still inside */ let b = 2"], table: try table("a.swift"))
        let second = ranges[1]
        #expect(second.first == TokenRange(location: 0, length: 15, kind: .comment))
        #expect(second.contains { $0.kind == .keyword && $0.location == 16 })
    }

    @Test("a blank line inside a block comment has no zero-width span and keeps the comment open")
    func blankLineInBlockComment() throws {
        let ranges = Tokenizer.highlight(["/* open", "", "*/ let a"], table: try table("a.swift"))
        #expect(ranges[1].isEmpty)
        #expect(ranges[2].first == TokenRange(location: 0, length: 2, kind: .comment))
    }

    @Test("a hunk starts outside any comment, whatever the previous hunk left open")
    func hunkResetsState() throws {
        let hunks = try PatchParser.hunks("@@ -1 +1 @@\n-a\n+/* open\n@@ -9 +9 @@\n-a\n+let b")
        let second = Tokenizer.highlight(hunks[1], path: "a.swift")
        #expect(second[1] == [TokenRange(location: 0, length: 3, kind: .keyword)])
    }

    @Test("a comment opened on a removed line does not reach the added lines")
    func sidesAreSeparate() throws {
        let hunk = try #require(PatchParser.hunks("@@ -1 +1 @@\n-/* old\n+let b").first)
        let ranges = Tokenizer.highlight(hunk, path: "a.swift")
        #expect(ranges[0].first?.kind == .comment)
        #expect(ranges[1] == [TokenRange(location: 0, length: 3, kind: .keyword)])
    }

    @Test("a file of an unknown type is plain text")
    func unknownExtension() throws {
        #expect(LanguageTable.forPath("notes.xyz") == nil)
        let hunk = try #require(PatchParser.hunks("@@ -1 +1 @@\n-let a\n+let b").first)
        #expect(Tokenizer.highlight(hunk, path: "notes.xyz") == [[], []])
    }

    @Test("offsets count UTF-16 units, the way an attributed string does")
    func utf16Offsets() throws {
        let ranges = Tokenizer.highlight(["let 🙂 = 1 // x"], table: try table("a.swift"))[0]
        let comment = try #require(ranges.first { $0.kind == .comment })
        #expect(comment.location == 11)
    }

    @Test("highlighting a file attaches each line's ranges to the line itself")
    func highlightedFile() throws {
        let hunks = try PatchParser.hunks("@@ -1 +1 @@\n-var a\n+let b")
        let file = DiffFile(path: "a.swift", previousPath: nil, change: .modified, additions: 1, deletions: 1,
                            content: .hunks(hunks))
        guard case .hunks(let result) = Tokenizer.highlighted(file).content else {
            Issue.record("content lost")
            return
        }
        #expect(result[0].lines.map(\.tokens) == [
            [TokenRange(location: 0, length: 3, kind: .keyword)],
            [TokenRange(location: 0, length: 3, kind: .keyword)],
        ])
        #expect(result[0].lines.map(\.text) == ["var a", "let b"])
    }

    @Test("an omitted file comes back unchanged")
    func highlightedOmitted() {
        let file = DiffFile(path: "a.png", previousPath: nil, change: .added, additions: 0, deletions: 0,
                            content: .omitted(.noTextChanges))
        #expect(Tokenizer.highlighted(file) == file)
    }
}
