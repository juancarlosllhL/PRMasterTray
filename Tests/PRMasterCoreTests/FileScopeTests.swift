import Testing
@testable import PRMasterCore

@Suite("FileScope")
struct FileScopeTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let path: String
        let section: FileSection
        var testDescription: String { "\(path) → \(section)" }
        init(_ path: String, _ section: FileSection) {
            self.path = path
            self.section = section
        }
    }

    /// Paths taken from the Lansweeper repositories surveyed for the defaults.
    @Test("the defaults sort the surveyed conventions", arguments: [
        Case("extension/src/__tests__/agent-bridge.test.ts", .tests),
        Case("dal-server/internal/handler/query_benchmark_test.go", .tests),
        Case("dal-clients/java/src/test/java/QueryTest.java", .tests),
        Case("plugins/inventory-scanner/tests/fixtures/host.json", .tests),
        Case("lecgraphql/audit_trails/testdata/event.json", .tests),
        Case("packages/component/src/components/ArtifactList.stories.tsx", .tests),
        Case("src/stories/Button.stories.tsx", .tests),
        Case("internal/testsupport/db.go", .tests),
        Case("src/boards/board.spec.ts", .tests),
        Case("dal-clients/csharp/DalClient.Tests/QueryTests.cs", .tests),
        Case("tests/__mocks__/dashboards.ts", .tests),
        Case("extension/vitest.config.ts", .tests),
        Case("src/test-setup.ts", .tests),
        Case("slack-pd-automation/tests/test_platform_hooks.py", .tests),
        Case("Tests/PRMasterCoreTests/GlobTests.swift", .tests),
        Case("src/__snapshots__/generate.test.ts.snap", .tests),

        Case("internal/app/asset/mock_agent_state_reader.go", .generated),
        Case("test/mocks/backend_mock.go", .generated),
        Case("schemas/proto/public.service.dal/packages/golang/v1/dal.pb.go", .generated),
        Case("schemas/proto/analytics/packages/nodejs/index.ts", .generated),
        Case("gen/api_grpc_pb.d.ts", .generated),
        Case("src/lansweeper.dal.v1.tonic.rs", .generated),
        Case("internal/adapter/graphql/generated/generated.go", .generated),
        Case("graph/models_gen.go", .generated),
        Case("src/adapter/graphql/api/resolvers-types.generated.ts", .generated),
        Case("src/pages/Sites/generated/Sites.query.generated.tsx", .generated),
        Case("generated/dataSetMaps/hardware.json", .generated),
        Case("src/core/vendors/schema/gateway/types.ts", .generated),
        Case("src/fragmentTypes.json", .generated),
        Case("terragrunt/ls/cpr/euw1/core/argocd/terragrunt.values.hcl", .generated),
        Case(".stacksets/core.autogen.json", .generated),
        Case("_values/cpr-euw1-core.auto.values.yaml", .generated),
        Case(".stages/prod/values.yaml", .generated),
        Case("hud/dist/index.js", .generated),
        Case("src/app.js.map", .generated),
        Case("pnpm-lock.yaml", .generated),
        Case("go.sum", .generated),
        Case("Cargo.lock", .generated),
        Case("charts/api/Chart.lock", .generated),
        Case("Package.resolved", .generated),

        Case("plans/20260929-review-file-scope.md", .other),
        Case("stories/106-e5eb-complete-P1-glob.md", .other),
        Case("reviews/pr-412.md", .other),
        Case("investigations/latency.md", .other),
        Case(".claude/settings.json", .other),
        Case(".wiz/session-map.json", .other),
        Case("CLAUDE.md", .other),
        Case("services/api/AGENTS.md", .other),
        Case(".vscode/settings.json", .other),
        Case("catalog-info.repo.yaml", .other),
        Case("src/assets/logo.png", .other),
        Case("fonts/Inter.woff2", .other),
    ])
    func defaults(_ example: Case) {
        #expect(FileScope().section(of: example.path) == example.section)
    }

    /// Each of these looked like a test or generated file to a naive rule, and is
    /// in fact code somebody wrote and a reviewer has to read.
    @Test("real code that only looks set-aside stays in the review", arguments: [
        "src/core/domain/analytics/features/dashboards/adapters/mock/MockDataAdapter.ts",
        "dal-server/internal/plan/planner.go",
        "src/main/jira/test-server.ts",
        "src/main/fontawesome/test-registry.ts",
        "internal/graphql/schema.resolvers.go",
        "migrations/generated-prod/001_init.sql",
        "src/types/global.d.ts",
        "src/stories/README.md",
        "docs/architecture.md",
        ".github/workflows/ci.yml",
        "src/icons/logo.svg",
        "build/icon.icns",
        "src/scss/vendor/_grid.scss",
    ])
    func falsePositives(_ path: String) {
        #expect(FileScope().section(of: path) == .review)
    }

    @Test("a generated file in a test directory is generated")
    func generatedBeatsTests() {
        let scope = FileScope(patterns: [.tests: ["tests/"], .generated: ["*.pb.go"], .other: ["*.go"]])
        #expect(scope.section(of: "tests/api.pb.go") == .generated)
        #expect(scope.section(of: "tests/api.go") == .tests)
        #expect(scope.section(of: "api.go") == .other)
    }

    @Test("custom lists replace the defaults; a missing list matches nothing")
    func customPatterns() {
        let scope = FileScope(patterns: [.tests: ["spec/"]])
        #expect(scope.section(of: "spec/board_spec.rb") == .tests)
        #expect(scope.section(of: "pnpm-lock.yaml") == .review)
    }

    @Test("a ! line re-includes a file in the review")
    func negation() {
        let scope = FileScope(patterns: [.tests: ["fixtures/", "!**/fixtures/seed.sql"]])
        #expect(scope.section(of: "db/fixtures/users.json") == .tests)
        #expect(scope.section(of: "db/fixtures/seed.sql") == .review)
    }

    static let platformInfraAttributes = """
    # Generated by the terragrunt stack
    .stacksets/*.autogen.json linguist-generated
    terragrunt/ls/**/* linguist-generated
    packages/server/sample-data/*.csv filter=lfs diff=lfs merge=lfs -text
    """

    @Test("files marked linguist-generated in .gitattributes are generated")
    func attributesMarkGenerated() {
        let scope = FileScope(gitAttributes: Self.platformInfraAttributes)
        #expect(scope.section(of: "terragrunt/ls/cpr/euw1/core/main.tf") == .generated)
        #expect(scope.section(of: "terragrunt-units-src/argocd/main.tf") == .review)
        #expect(scope.section(of: "packages/server/sample-data/assets.csv") == .review)
        #expect(FileScope(gitAttributes: nil).section(of: "terragrunt/ls/cpr/euw1/core/main.tf") == .review)
    }

    @Test("an attribute set false overrides the generated patterns", arguments: [
        "generated/** -linguist-generated",
        "generated/** !linguist-generated",
        "generated/** linguist-generated=false",
    ])
    func attributesUnmark(_ line: String) {
        let scope = FileScope(gitAttributes: line)
        #expect(scope.section(of: "generated/dataSetMaps/hardware.json") == .review)
        #expect(scope.section(of: "generated/dataSetMaps/hardware.test.ts") == .tests)
    }

    @Test("[attr] macro definitions are not paths")
    func attributesSkipMacros() {
        let scope = FileScope(gitAttributes: "[attr]gen linguist-generated\nCargo.lock linguist-generated=false")
        #expect(scope.section(of: "tgen") == .review)
        #expect(scope.section(of: "Cargo.lock") == .review)
    }

    @Test("linguist-generated=true counts as set")
    func attributesExplicitTrue() {
        #expect(FileScope(gitAttributes: "api/*.yaml linguist-generated=true").section(of: "api/crd.yaml") == .generated)
    }

    @Test("scopes compare by their rules")
    func equality() {
        #expect(FileScope() == FileScope())
        #expect(FileScope() != FileScope(gitAttributes: "a linguist-generated"))
        #expect(FileScope() != FileScope(patterns: [:]))
    }
}
