import Testing
@testable import PRMasterCore

@Suite("Glob")
struct GlobTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let pattern: String
        let path: String
        let matches: Bool
        var testDescription: String { "\(pattern) \(matches ? "matches" : "skips") \(path)" }
    }

    @Test("gitignore semantics", arguments: [
        // No slash: the name at any depth, file or directory.
        Case(pattern: "*_test.go", path: "store_test.go", matches: true),
        Case(pattern: "*_test.go", path: "internal/app/store_test.go", matches: true),
        Case(pattern: "*_test.go", path: "internal/app/store.go", matches: false),
        Case(pattern: "generated", path: "pkg/generated/models.go", matches: true),
        // A leading slash anchors to the repository root.
        Case(pattern: "/plans/", path: "plans/20260929-scope.md", matches: true),
        Case(pattern: "/plans/", path: "docs/plans/scope.md", matches: false),
        // A trailing slash means a directory: everything under it, never a file.
        Case(pattern: "test/", path: "src/test/java/AppTest.java", matches: true),
        Case(pattern: "test/", path: "src/test", matches: false),
        Case(pattern: "dist/", path: "hud/dist/index.js", matches: true),
        // A slash in the middle anchors too.
        Case(pattern: "terragrunt/ls/**/*", path: "terragrunt/ls/cpr/euw1/terragrunt.values.hcl", matches: true),
        Case(pattern: "terragrunt/ls/**/*", path: "infra/terragrunt/ls/a.hcl", matches: false),
        // ** spans zero or more directories; * and ? stay inside one.
        Case(pattern: "**/schemas/proto/*/packages/**", path: "schemas/proto/dal/packages/golang/v1/a.pb.go", matches: true),
        Case(pattern: "**/schemas/proto/*/packages/**", path: "x/schemas/proto/dal/packages/a.ts", matches: true),
        Case(pattern: "**/schemas/proto/*/packages/**", path: "schemas/proto/a/b/packages/a.ts", matches: false),
        Case(pattern: "**/graphql/**/generated/**", path: "internal/adapter/graphql/generated/generated.go", matches: true),
        Case(pattern: "src/*.ts", path: "src/a/b.ts", matches: false),
        Case(pattern: "mock_?.go", path: "mock_a.go", matches: true),
        Case(pattern: "mock_?.go", path: "mock_ab.go", matches: false),
        // Braces and classes.
        Case(pattern: "*.{test,spec}.{ts,tsx}", path: "src/Board.spec.tsx", matches: true),
        Case(pattern: "*.{test,spec}.{ts,tsx}", path: "src/Board.tsx", matches: false),
        Case(pattern: "{go.sum,Cargo.lock}", path: "Cargo.lock", matches: true),
        Case(pattern: "*.{js,css}.map", path: "dist/a.js.map", matches: true),
        Case(pattern: "*.{js,css}.map", path: "internal/geo.map", matches: false),
        Case(pattern: "file[0-9].txt", path: "file7.txt", matches: true),
        Case(pattern: "file[!0-9].txt", path: "file7.txt", matches: false),
        // Regex metacharacters are literal.
        Case(pattern: "*.pb.go", path: "apbxgo", matches: false),
        Case(pattern: "a+b(c).txt", path: "a+b(c).txt", matches: true),
        // Case-sensitive, like git.
        Case(pattern: "Tests/", path: "Tests/PRMasterCoreTests/GlobTests.swift", matches: true),
        Case(pattern: "tests/", path: "Tests/PRMasterCoreTests/GlobTests.swift", matches: false),
    ])
    func semantics(_ example: Case) throws {
        #expect(try Glob(example.pattern).matches(example.path) == example.matches)
    }

    @Test("a leading ! negates the rule, and \\! makes it literal")
    func negation() throws {
        #expect(try Glob("!fixtures/").negated)
        #expect(try !Glob("fixtures/").negated)
        #expect(try Glob("\\!important.md").matches("!important.md"))
    }

    @Test("unbalanced braces and brackets, and empty patterns, are refused", arguments: ["*.{ts,tsx", "file[0-9.txt", "!", "/"])
    func invalid(_ pattern: String) {
        #expect(throws: GlobError.self) { try Glob(pattern) }
    }

    @Test("the last matching rule decides; no match is no verdict")
    func listVerdict() {
        let list = GlobList(lines: ["fixtures/", "!**/fixtures/seed.json", "# a comment", "", "  "])
        #expect(list.verdict(for: "api/fixtures/board.json") == true)
        #expect(list.verdict(for: "api/fixtures/seed.json") == false)
        #expect(list.verdict(for: "api/board.ts") == nil)
        #expect(list.invalidLines.isEmpty)
    }

    @Test("an invalid line is reported and skipped, the rest still apply")
    func listInvalidLines() {
        let list = GlobList(lines: ["*.{ts", "*_test.go"])
        #expect(list.invalidLines == ["*.{ts"])
        #expect(list.verdict(for: "a_test.go") == true)
    }
}
