// Where a changed file belongs in the review window. Only "review" is the
// review; the rest are set aside, still one click away. Port of FileScope.swift
// and GitAttributes.swift.
import { GlobList } from "./glob.js";

export { compileGlob, GlobList } from "./glob.js";

export const SECTIONS = ["review", "tests", "generated", "other"];

// The set-aside sections, in the order the window lists them.
export const SECONDARY = ["tests", "generated", "other"];

export const SECTION_TITLES = { review: "Review", tests: "Tests", generated: "Generated", other: "Other" };

// A generated test mock is generated before it is a test.
const PRECEDENCE = ["generated", "tests", "other"];

// Drawn from the test and codegen conventions of the Lansweeper repositories.
// Leaves out `mock/`, `plan/`, `vendor/` and `build/`: each holds real code somewhere.
export const DEFAULT_PATTERNS = {
  tests: [
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
  generated: [
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
  other: [
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
};

// Reads the `linguist-generated` marks GitHub itself uses to collapse generated
// files, which its API never reports. A `!` rule for each path un-marked with
// `-`, `!` or `=false`.
export function generatedRules(text) {
  const lines = [];
  for (const line of text.split(/\r?\n/)) {
    const [pattern, ...attributes] = line.trim().split(/\s+/);
    if (!pattern || pattern.startsWith("#") || pattern.startsWith("!") || pattern.startsWith("[attr]")) continue;
    for (const attribute of attributes) {
      if (attribute === "linguist-generated" || attribute === "linguist-generated=true") lines.push(pattern);
      else if (["-linguist-generated", "!linguist-generated", "linguist-generated=false"].includes(attribute)) lines.push(`!${pattern}`);
    }
  }
  return new GlobList(lines);
}

// A section missing from `patterns` matches nothing.
export function compileScope({ patterns = DEFAULT_PATTERNS, gitAttributes = null } = {}) {
  return {
    lists: Object.fromEntries(Object.entries(patterns).map(([section, lines]) => [section, new GlobList(lines)])),
    attributes: gitAttributes === null ? null : generatedRules(gitAttributes),
  };
}

// Accepts either a compiled scope or the { patterns, gitAttributes } it is built from.
export function sectionOf(path, scope) {
  const { lists, attributes } = scope.lists ? scope : compileScope(scope);
  const marked = attributes?.verdict(path) ?? null;
  for (const section of PRECEDENCE) {
    if (section === "generated" && marked !== null) {
      if (marked) return "generated";
      continue; // the repository says this one is not generated
    }
    if (lists[section]?.verdict(path) === true) return section;
  }
  return "review";
}

// What the sidebar and the diff's divider both read, e.g. "Tests · 12".
export const sectionHeading = (section, count) => `${SECTION_TITLES[section]} · ${count}`;
