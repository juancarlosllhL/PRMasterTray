import Foundation

/// Where a changed file belongs in the review window. Only `.review` is the review;
/// the rest are set aside, still one click away.
public enum FileSection: String, CaseIterable, Sendable {
    case review, tests, generated, other

    /// The set-aside sections, in the order the window lists them.
    public static let secondary: [FileSection] = [.tests, .generated, .other]

    /// A generated test mock is generated before it is a test.
    static let precedence: [FileSection] = [.generated, .tests, .other]
}

public struct FileScope: Sendable, Equatable {

    private let lists: [FileSection: GlobList]
    private let attributes: GlobList?

    /// A section missing from `patterns` matches nothing.
    public init(patterns: [FileSection: [String]] = defaultPatterns, gitAttributes: String? = nil) {
        lists = patterns.mapValues(GlobList.init(lines:))
        attributes = gitAttributes.map(GitAttributes.generatedRules(in:))
    }

    public func section(of path: String) -> FileSection {
        let marked = attributes?.verdict(for: path)
        for section in FileSection.precedence {
            if section == .generated, let marked {
                if marked { return .generated } else { continue }
            }
            if lists[section]?.verdict(for: path) == true { return section }
        }
        return .review
    }

    public func invalidLines(in section: FileSection) -> [String] {
        lists[section]?.invalidLines ?? []
    }

    /// Drawn from the test and codegen conventions of the Lansweeper repositories.
    /// Leaves out `mock/`, `plan/`, `vendor/` and `build/`: each holds real code somewhere.
    public static let defaultPatterns: [FileSection: [String]] = [
        .tests: [
            "*_test.go",
            "*.{test,spec}.{ts,tsx,js,jsx,mjs,cjs}",
            "__tests__/",
            "__mocks__/",
            "__fixtures__/",
            "__snapshots__/",
            "*.snap",
            "testdata/",
            "test/",
            "tests/",
            "Tests/",
            "fixtures/",
            "e2e/",
            "testsupport/",
            "test-utils/",
            "testutil/",
            "testutils/",
            "*.Tests/",
            "*Tests.cs",
            "test_*.py",
            "*_test.py",
            "conftest.py",
            "*.stories.{ts,tsx,js,jsx,mdx}",
            "{vitest,jest,playwright,cypress}.config.*",
            "{vitest,jest}.setup.*",
            "test-setup.ts",
        ],
        .generated: [
            "*.pb.go",
            "*.pb.gw.go",
            "*_pb.js",
            "*_pb.d.ts",
            "*.tonic.rs",
            "**/schemas/proto/*/packages/**",
            "mock_*.go",
            "*_mock.go",
            "models_gen.go",
            "**/graphql/**/generated/**",
            "*.generated.{ts,tsx}",
            "generated/",
            "**/schema/{gateway,subs}/types.ts",
            "fragmentTypes.json",
            "terragrunt.values.hcl",
            "*.autogen.*",
            "*.auto.values.yaml",
            ".stages/",
            "dist/",
            "*.{js,css}.map",
            "*.min.{js,css}",
            "*.Designer.cs",
            "*ModelSnapshot.cs",
            "{package-lock.json,pnpm-lock.yaml,yarn.lock,bun.lock,bun.lockb}",
            "{go.sum,go.work.sum,Cargo.lock,Chart.lock,.terraform.lock.hcl}",
            "{poetry.lock,uv.lock,Gemfile.lock,composer.lock,packages.lock.json,Package.resolved}",
        ],
        .other: [
            "/plans/",
            "/stories/",
            "/reviews/",
            "/investigations/",
            ".claude/",
            ".cursor/",
            ".wiz/",
            "CLAUDE.md",
            "AGENTS.md",
            ".vscode/",
            "catalog-info*.yaml",
            "*.{png,jpg,jpeg,gif,ico,webp,woff,woff2,ttf,otf,eot,pdf,xlsx}",
        ],
    ]
}
