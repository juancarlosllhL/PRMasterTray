import Foundation
import Testing
@testable import PRMasterCore

enum ShikiScript {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/shiki.js")

    static let highlighter: ShikiHighlighter = {
        do {
            return try ShikiHighlighter(script: String(contentsOf: url, encoding: .utf8))
        } catch {
            fatalError("Resources/shiki.js did not load: \(error)")
        }
    }()
}

private func file(_ path: String, _ patch: String) throws -> DiffFile {
    DiffFile(path: path, previousPath: nil, change: .modified, additions: 1, deletions: 1,
             content: .hunks(try PatchParser.hunks(patch)))
}

private func lines(of file: DiffFile) -> [DiffLine] {
    guard case .hunks(let hunks) = file.content else { return [] }
    return hunks.flatMap(\.lines)
}

/// The new-side lines of a one-hunk patch made of `texts`, highlighted.
private func highlighted(_ path: String, _ texts: [String], theme: SyntaxTheme = .light) async throws -> [DiffLine] {
    let patch = "@@ -0,0 +1,\(texts.count) @@\n" + texts.map { "+" + $0 }.joined(separator: "\n")
    return lines(of: await ShikiScript.highlighter.highlight(try file(path, patch), theme: theme))
}

/// The colour covering `word` in `line`, or nil where the text is plain.
private func colour(of word: String, in line: DiffLine) throws -> RGB? {
    let offset = try #require(line.text.range(of: word)).lowerBound.utf16Offset(in: line.text)
    return line.tokens.first { $0.location <= offset && offset < $0.location + $0.length }?.colour
}

@Suite("Shiki highlighter")
struct ShikiHighlighterTests {

    @Test(
        "each language colours its own syntax",
        arguments: [
            ("a.swift", "let value = 1", "let"),
            ("main.go", "func main() {}", "func"),
            ("app.ts", "const x: number = 1", "const"),
            ("view.tsx", "export const A = () => <div />", "export"),
            ("app.js", "return x", "return"),
            ("Program.cs", "public class Widget {}", "class"),
            ("tool.py", "def run():", "def"),
            ("data.json", "{\"on\": true}", "true"),
            ("ci.yml", "enabled: false", "false"),
            ("build.sh", "if [ -f x ]; then echo; fi", "then"),
            ("README.md", "# Title", "Title"),
            ("index.html", "<div class=\"a\"></div>", "div"),
            ("site.css", "body { color: red; }", "color"),
            ("q.sql", "SELECT id FROM users", "SELECT"),
            ("lib.rs", "fn main() {}", "fn"),
            ("App.java", "public class App {}", "class"),
            ("Main.kt", "fun main() {}", "fun"),
            ("Dockerfile", "FROM alpine", "FROM"),
            ("Cargo.toml", "name = \"x\"", "\"x\""),
            ("main.tf", "resource \"a\" \"b\" {}", "resource"),
            ("pom.xml", "<project></project>", "project"),
            ("app.rb", "def run; end", "def"),
            ("main.cpp", "int main() {\n  return 0;\n}", "int"),
            ("q.graphql", "query Viewer { login }", "query"),
            ("Makefile", "build:\n\tswift build", "build"),
        ]
    )
    func languages(path: String, text: String, word: String) async throws {
        let first = try #require(try await highlighted(path, text.components(separatedBy: "\n")).first)
        #expect(try colour(of: word, in: first) != nil, "\(word) in \(path) is plain")
    }

    @Test("every mapped language is one the bundle carries")
    func mappedLanguagesExist() async {
        let bundled = Set(await ShikiScript.highlighter.languages())
        #expect(bundled.count == 25)
        #expect(Set(SyntaxLanguage.byExtension.values).union(SyntaxLanguage.byFileName.values).isSubset(of: bundled))
    }

    @Test("a comment marker inside a string stays part of the string")
    func markerInString() async throws {
        let line = try #require(try await highlighted("a.swift", [#"let url = "https://github.com" // home"#]).first)
        #expect(try colour(of: "github", in: line) == colour(of: "\"https", in: line))
        #expect(try colour(of: "github", in: line) != colour(of: "home", in: line))
    }

    @Test("a comment after a call is a comment, which JavaScriptCore's regex JIT gets wrong")
    func trailingComment() async throws {
        let result = try await highlighted("a.swift", ["// whole", "foo() // done", "let y = a } // done"])
        let comment = try colour(of: "whole", in: result[0])
        #expect(comment != nil)
        #expect(try colour(of: "done", in: result[1]) == comment)
        #expect(try colour(of: "done", in: result[2]) == comment)
    }

    @Test("a block comment carries to the next line of the same side")
    func blockCommentCarries() async throws {
        let result = try await highlighted("a.swift", ["// x", "let a = 1 /* open", "still inside */ let b = 2"])
        #expect(try colour(of: "still", in: result[2]) == colour(of: "x", in: result[0]))
        #expect(try colour(of: "let", in: result[2]) == colour(of: "let", in: result[1]))
    }

    @Test("a hunk starts outside any comment, whatever the previous hunk left open")
    func hunkResetsState() async throws {
        let diff = try file("a.swift", "@@ -1 +1 @@\n-a\n+/* open\n@@ -9 +9 @@\n-a\n+let b")
        let result = lines(of: await ShikiScript.highlighter.highlight(diff, theme: .light))
        #expect(try colour(of: "let", in: result[3]) != colour(of: "open", in: result[1]))
        #expect(try colour(of: "let", in: result[3]) != nil)
    }

    @Test("a comment opened on a removed line does not reach the added lines")
    func sidesAreSeparate() async throws {
        let diff = try file("a.swift", "@@ -1 +1 @@\n-/* old\n+let b")
        let result = lines(of: await ShikiScript.highlighter.highlight(diff, theme: .light))
        #expect(try colour(of: "let", in: result[1]) != colour(of: "old", in: result[0]))
        #expect(try colour(of: "let", in: result[1]) != nil)
    }

    @Test("offsets count UTF-16 units, the way an attributed string does")
    func utf16Offsets() async throws {
        let line = try #require(try await highlighted("a.swift", ["let 🙂 = 1 // x"]).first)
        #expect(line.tokens.contains { $0.location == 11 && $0.length == 4 })
    }

    @Test("a carriage return at the end of a line keeps lines one to one")
    func carriageReturn() async throws {
        let result = try await highlighted("a.swift", ["let a = 1\r", "let b = 2"])
        #expect(result.count == 2)
        #expect(try colour(of: "let", in: result[1]) != nil)
        #expect(result[1].tokens.first?.location == 0)
    }

    @Test("the theme decides the colours")
    func themes() async throws {
        let light = try #require(try await highlighted("a.swift", ["let a = 1"], theme: .light).first)
        let dark = try #require(try await highlighted("a.swift", ["let a = 1"], theme: .dark).first)
        #expect(try colour(of: "let", in: light) != colour(of: "let", in: dark))
    }

    @Test("text in the theme's plain foreground carries no range")
    func plainTextHasNoRange() async throws {
        let line = try #require(try await highlighted("a.swift", ["let value = 1"]).first)
        #expect(try colour(of: "value", in: line) == nil)
    }

    @Test("a file of an unknown type comes back unchanged")
    func unknownExtension() async throws {
        #expect(SyntaxLanguage.forPath("notes.xyz") == nil)
        let diff = try file("notes.xyz", "@@ -1 +1 @@\n-let a\n+let b")
        #expect(await ShikiScript.highlighter.highlight(diff, theme: .light) == diff)
    }

    @Test("a line Shiki would split in two leaves the whole file plain")
    func lineCountMismatch() async throws {
        let line = DiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "let a\nlet b")
        let hunk = Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1, context: "", lines: [line])
        let diff = DiffFile(path: "a.swift", previousPath: nil, change: .added, additions: 1, deletions: 0,
                            content: .hunks([hunk]))
        #expect(await ShikiScript.highlighter.highlight(diff, theme: .light) == diff)
    }

    @Test("a script that throws leaves the file plain and keeps the highlighter working")
    func scriptThrows() async throws {
        let failing = try ShikiHighlighter(script: """
            globalThis.prmaster = { highlight() { throw new Error('boom') }, languages: () => ['swift'] }
            """)
        let diff = try file("a.swift", "@@ -1 +1 @@\n-let a\n+let b")
        #expect(await failing.highlight(diff, theme: .light) == diff)
        #expect(await failing.highlight(diff, theme: .light) == diff)
    }

    @Test("a script without the highlighter entry point is refused")
    func missingEntryPoint() {
        #expect(throws: ShikiHighlighter.LoadError.self) { try ShikiHighlighter(script: "var x = 1") }
        #expect(throws: ShikiHighlighter.LoadError.self) { try ShikiHighlighter(script: "this is not javascript") }
    }

    @Test("an omitted file comes back unchanged")
    func omitted() async {
        let diff = DiffFile(path: "a.png", previousPath: nil, change: .added, additions: 0, deletions: 0,
                            content: .omitted(.noTextChanges))
        #expect(await ShikiScript.highlighter.highlight(diff, theme: .light) == diff)
    }
}
