import { test } from "node:test";
import assert from "node:assert/strict";
import { compileGlob, GlobList, generatedRules, sectionOf, DEFAULT_PATTERNS } from "../src/core/fileScope.js";

const matches = (pattern, path) => compileGlob(pattern).matches(path);

test("a pattern with no slash matches at any depth, like .gitignore", () => {
  assert.equal(matches("*_test.go", "pkg/a/x_test.go"), true);
  assert.equal(matches("*_test.go", "x_test.go"), true);
  assert.equal(matches("*_test.go", "x_test.go.bak"), false);
  assert.equal(matches("CLAUDE.md", "docs/CLAUDE.md"), true);
});

test("a trailing slash means a directory, so everything beneath it", () => {
  assert.equal(matches("test/", "test/a.js"), true);
  assert.equal(matches("test/", "src/test/a/b.js"), true);
  assert.equal(matches("test/", "src/contest/a.js"), false);
  assert.equal(matches("test/", "test"), false); // a file called test is not the directory
});

test("a slash inside the pattern, or a leading one, anchors it to the root", () => {
  assert.equal(matches("/plans/", "plans/x.md"), true);
  assert.equal(matches("/plans/", "docs/plans/x.md"), false);
  assert.equal(matches("docs/*.md", "docs/a.md"), true);
  assert.equal(matches("docs/*.md", "x/docs/a.md"), false);
});

test("* stops at a slash; ** crosses it", () => {
  assert.equal(matches("a/*/c", "a/b/c"), true);
  assert.equal(matches("a/*/c", "a/b/x/c"), false);
  assert.equal(matches("a/**/c", "a/b/x/c"), true);
  assert.equal(matches("a/**/c", "a/c"), true);
  assert.equal(matches("**/schemas/proto/*/packages/**", "x/schemas/proto/v1/packages/a/b.proto"), true);
});

test("? matches one character but not a slash, and [..] sets work, including negation", () => {
  assert.equal(matches("a?c", "abc"), true);
  assert.equal(matches("a?c", "a/c"), false);
  assert.equal(matches("file[12].txt", "file2.txt"), true);
  assert.equal(matches("file[!12].txt", "file3.txt"), true);
  assert.equal(matches("file[!12].txt", "file1.txt"), false);
});

test("{a,b} alternation, including nested use", () => {
  assert.equal(matches("*.{test,spec}.{ts,tsx}", "src/a.test.tsx"), true);
  assert.equal(matches("*.{test,spec}.{ts,tsx}", "src/a.spec.ts"), true);
  assert.equal(matches("*.{test,spec}.{ts,tsx}", "src/a.story.ts"), false);
  assert.equal(matches("{package-lock.json,go.sum}", "svc/go.sum"), true);
});

test("matching is case-sensitive, like git, and regex characters are literal", () => {
  assert.equal(matches("Tests/", "tests/a.cs"), false);
  assert.equal(matches("a.b", "aXb"), false);
  assert.equal(matches("a+b", "a+b"), true);
});

test("an escaped character is literal", () => {
  assert.equal(matches("a\\*b", "a*b"), true);
  assert.equal(matches("a\\*b", "aXb"), false);
});

test("bad patterns are refused rather than half-compiled", () => {
  assert.throws(() => compileGlob(""), { code: "empty" });
  assert.throws(() => compileGlob("!"), { code: "empty" });
  assert.throws(() => compileGlob("{a,b"), { code: "unbalancedBrace" });
  assert.throws(() => compileGlob("a[bc"), { code: "unbalancedBracket" });
  assert.throws(() => compileGlob("a[]"), { code: "unbalancedBracket" });
});

test("a list skips blanks and comments, and the last matching rule decides", () => {
  const list = new GlobList(["# generated", "", "*.lock", "!keep.lock"]);
  assert.equal(list.verdict("a/x.lock"), true);
  assert.equal(list.verdict("keep.lock"), false); // re-included by a ! rule
  assert.equal(list.verdict("a.txt"), null); // no rule applies
});

test("invalid lines are reported, not silently dropped, and do not stop the rest", () => {
  const list = new GlobList(["*.lock", "{broken", "[x"]);
  assert.deepEqual(list.invalidLines, ["{broken", "[x"]);
  assert.equal(list.verdict("a.lock"), true);
});

// ---- .gitattributes ---------------------------------------------------------

test("linguist-generated marks a path; the un-marking spellings re-include it", () => {
  const rules = generatedRules(["# comment", "dist/** linguist-generated", "*.pb.go linguist-generated=true", "dist/keep.js -linguist-generated", "src/x.ts linguist-generated=false", "*.md text"].join("\n"));
  assert.equal(rules.verdict("dist/a.js"), true);
  assert.equal(rules.verdict("a/b.pb.go"), true);
  assert.equal(rules.verdict("dist/keep.js"), false);
  assert.equal(rules.verdict("src/x.ts"), false);
  assert.equal(rules.verdict("README.md"), null);
});

test("macros and negated patterns in .gitattributes are not rules", () => {
  const rules = generatedRules(["[attr]vendored linguist-generated", "!x linguist-generated"].join("\n"));
  assert.deepEqual(rules.globs.length, 0);
});

// ---- File sections ----------------------------------------------------------

const scope = (patterns, gitAttributes) => ({ patterns, gitAttributes });

test("default sections: tests, generated, other, and everything else is review", () => {
  const s = scope(DEFAULT_PATTERNS);
  assert.equal(sectionOf("src/app.ts", s), "review");
  assert.equal(sectionOf("src/app.test.ts", s), "tests");
  assert.equal(sectionOf("pkg/handler_test.go", s), "tests");
  assert.equal(sectionOf("web/__snapshots__/a.snap", s), "tests");
  assert.equal(sectionOf("pnpm-lock.yaml", s), "generated");
  assert.equal(sectionOf("api/x.pb.go", s), "generated");
  assert.equal(sectionOf("plans/2026-plan.md", s), "other");
  assert.equal(sectionOf("docs/plans/x.md", s), "review"); // /plans/ is anchored to the root
  assert.equal(sectionOf("assets/logo.png", s), "other");
});

test("a generated test mock is generated before it is a test", () => {
  assert.equal(sectionOf("pkg/mocks/mock_store.go", scope(DEFAULT_PATTERNS)), "generated");
});

test("a repo's own linguist-generated marks decide, and a re-inclusion keeps a file in review", () => {
  const attrs = ["gen/** linguist-generated", "gen/hand.ts -linguist-generated"].join("\n");
  const s = scope({ tests: [], generated: [], other: [] }, attrs);
  assert.equal(sectionOf("gen/a.ts", s), "generated");
  assert.equal(sectionOf("gen/hand.ts", s), "review");
});

test("a section missing from the patterns matches nothing", () => {
  assert.equal(sectionOf("a.test.ts", scope({})), "review");
});
