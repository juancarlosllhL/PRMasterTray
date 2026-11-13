import { test } from "node:test";
import assert from "node:assert/strict";
import { highlightFile, languageForPath, loadShiki, hunkSides, tokensToSpans } from "../src/core/highlight.js";

test("language comes from the file name first, then the lower-cased extension", () => {
  assert.equal(languageForPath("src/app.ts"), "typescript");
  assert.equal(languageForPath("src/App.TSX"), "tsx");
  assert.equal(languageForPath("build/Dockerfile"), "docker");
  assert.equal(languageForPath("a/b/Makefile"), "make");
  assert.equal(languageForPath("infra/main.tf"), "hcl");
  assert.equal(languageForPath("notes.unknownext"), null);
  assert.equal(languageForPath("LICENSE"), null);
});

const line = (kind, text) => ({ kind, text, oldNumber: null, newNumber: null, noNewlineAtEnd: false });

test("a hunk is read as the two files it comes from", () => {
  const sides = hunkSides({ lines: [line("context", "c"), line("removed", "r"), line("added", "a")] });
  assert.deepEqual([sides.oldTexts, sides.newTexts], [["c", "r"], ["c", "a"]]);
  assert.deepEqual([sides.oldIndices, sides.newIndices], [[0, 1], [0, 2]]);
});

test("tokens become spans that cover the whole line, colour only where there is some", () => {
  const spans = tokensToSpans("foo bar", [{ start: 0, end: 3, colour: "#FF0000", style: 1 }, { start: 4, end: 7, colour: "#00FF00", style: 6 }]);
  assert.deepEqual(spans, [
    { text: "foo", colour: "#FF0000", italic: true, bold: false, underline: false },
    { text: " ", colour: null, italic: false, bold: false, underline: false },
    { text: "bar", colour: "#00FF00", italic: false, bold: true, underline: true },
  ]);
  assert.deepEqual(tokensToSpans("plain", []).map((s) => s.text), ["plain"]);
});

test("tokens that fall outside the line are ignored rather than trusted", () => {
  assert.deepEqual(tokensToSpans("abc", [{ start: 2, end: 9, colour: "#111111", style: 0 }]).map((s) => s.text), ["abc"]);
  assert.deepEqual(tokensToSpans("abc", [{ start: -1, end: 2, colour: "#111111", style: 0 }]).map((s) => s.text), ["abc"]);
});

// The real Shiki bundle: no stand-in for the grammar.
const shiki = loadShiki();
const file = (path, lines, content) => ({ path, previousPath: null, change: "modified", additions: 1, deletions: 1, viewed: "UNVIEWED", content: content ?? { kind: "hunks", hunks: [{ oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, context: "", lines }] } });

test("TypeScript is coloured with Shiki's own grammar: keywords get a colour, the line text is unchanged", async () => {
  const f = file("a.ts", [line("context", "const answer = 42;"), line("removed", "let old = 1;"), line("added", "let fresh = 2;")]);
  const out = await highlightFile(f, "github-dark-default", shiki.highlight);
  const lines = out.content.hunks[0].lines;
  assert.deepEqual(lines.map((l) => l.text), ["const answer = 42;", "let old = 1;", "let fresh = 2;"]); // text is never altered
  for (const l of lines) {
    assert.equal(l.spans.map((s) => s.text).join(""), l.text); // spans tile the line exactly
    assert.ok(l.spans.some((s) => s.colour), `no colour on "${l.text}"`);
  }
  assert.equal(lines[0].spans[0].text, "const"); // the keyword is its own span
});

test("a removed line is coloured from the old file and an added one from the new", async () => {
  // Two sides that only parse correctly as different languages' states: a block comment opens on the old side only.
  const f = file("a.ts", [line("removed", "/* open"), line("added", "const x = 1;"), line("context", "const y = 2;")]);
  const out = await highlightFile(f, "github-dark-default", shiki.highlight);
  const [removed, added, context] = out.content.hunks[0].lines;
  assert.equal(removed.spans.map((s) => s.text).join(""), "/* open");
  assert.ok(added.spans.some((s) => s.colour && s.text === "const"), "the new side must not inherit the old side's open comment");
  assert.ok(context.spans.length > 0);
});

test("an unknown language, an omitted file or a hunk-less one comes back untouched", async () => {
  const f = file("notes.txt", [line("added", "hello")]);
  assert.equal(await highlightFile(f, "github-dark-default", shiki.highlight), f);
  const omitted = file("a.ts", [], { kind: "omitted", reason: "tooLarge" });
  assert.equal(await highlightFile(omitted, "github-dark-default", shiki.highlight), omitted);
});

test("a highlighter that fails or answers out of shape costs the colour, never the diff", async () => {
  const f = file("a.ts", [line("added", "const x = 1;")]);
  assert.equal(await highlightFile(f, "t", () => { throw new Error("boom"); }), f);
  assert.equal(await highlightFile(f, "t", () => "not json"), f);
  assert.equal(await highlightFile(f, "t", () => JSON.stringify({ colours: [], segments: [] })), f); // wrong segment count
  assert.equal(await highlightFile(f, "t", () => JSON.stringify({ colours: [], segments: [null, null] })), f); // lines did not map one to one
});

test("the bundled script knows the languages and themes the window asks for", () => {
  const languages = shiki.languages();
  for (const wanted of ["typescript", "go", "csharp", "yaml", "swift", "docker"]) assert.ok(languages.includes(wanted), wanted);
  assert.ok(shiki.themeColours("github-dark-default").length > 0);
});
