import { test } from "node:test";
import assert from "node:assert/strict";
import { DiffView, buildRows, findMatches, splitHunk } from "../src/core/diffView.js";

const line = (kind, text, oldNumber = null, newNumber = null) => ({ kind, text, oldNumber, newNumber, noNewlineAtEnd: false });
const hunk = (lines, context = "") => ({ oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, context, lines });
const file = (path, hunks, over = {}) => ({ path, previousPath: null, change: "modified", additions: 1, deletions: 1, content: { kind: "hunks", hunks }, viewed: "UNVIEWED", ...over });

const simple = hunk([line("context", "keep", 1, 1), line("removed", "old", 2, null), line("added", "new", null, 2)], "fn()");

test("unified rows: header, then one row per line, with the hunk header text", () => {
  const rows = buildRows([{ section: "review", files: [file("a.js", [simple])] }], "unified", () => false);
  assert.deepEqual(rows.map((r) => r.type), ["fileHeader", "hunkHeader", "line", "line", "line"]);
  assert.equal(rows[1].text, "@@ -1,2 +1,2 @@ fn()");
  assert.equal(buildRows([{ section: "review", files: [file("a.js", [hunk([], "")])] }], "unified", () => false)[1].text, "@@ -1,2 +1,2 @@");
});

test("split pairs removed and added lines in order; context sits on both sides", () => {
  const rows = splitHunk(simple);
  assert.deepEqual(rows.map((r) => r.type), ["hunkHeader", "pair", "pair"]);
  assert.equal(rows[1].left.text, "keep");
  assert.equal(rows[1].right.text, "keep");
  assert.deepEqual([rows[2].left.text, rows[2].right.text], ["old", "new"]);
});

test("split: an uneven change block leaves the short side blank", () => {
  const rows = splitHunk(hunk([line("removed", "a", 1), line("removed", "b", 2), line("added", "c", null, 1)]));
  assert.deepEqual(rows.slice(1).map((r) => [r.left?.text ?? null, r.right?.text ?? null]), [["a", "c"], ["b", null]]);
  const onlyAdded = splitHunk(hunk([line("added", "x", null, 1)]));
  assert.deepEqual([onlyAdded[1].left, onlyAdded[1].right.text], [null, "x"]);
});

test("split: removals after additions start a new block rather than pairing across it", () => {
  const rows = splitHunk(hunk([line("added", "n1", null, 1), line("removed", "o1", 1), line("added", "n2", null, 2)]));
  assert.deepEqual(rows.slice(1).map((r) => [r.left?.text ?? null, r.right?.text ?? null]), [[null, "n1"], ["o1", "n2"]]);
});

test("a collapsed file shows only its header; an omitted one says why", () => {
  const omitted = file("big.bin", [], { content: { kind: "omitted", reason: "tooLarge" } });
  const rows = buildRows([{ section: "review", files: [file("a.js", [simple]), omitted] }], "unified", (p) => p === "a.js");
  assert.deepEqual(rows.map((r) => r.type), ["fileHeader", "fileHeader", "omitted"]);
  assert.equal(rows[2].reason, "tooLarge");
});

test("set-aside groups come after review, each behind a divider with its count", () => {
  const groups = [
    { section: "tests", files: [file("t1.js", [simple]), file("t2.js", [simple])] },
    { section: "review", files: [file("a.js", [simple])] },
  ];
  const rows = buildRows(groups, "unified", () => true);
  assert.deepEqual(rows.map((r) => r.type === "section" ? `section:${r.section}:${r.count}` : r.path), ["a.js", "section:tests:2", "t1.js", "t2.js"]);
});

// ---- State ------------------------------------------------------------------

const diff = (files) => ({ files });
const loaded = (files, over = {}) => {
  const view = new DiffView(over);
  view.load(diff(files));
  return view;
};

test("files are sorted into sections by the scope, and review comes first", () => {
  const view = loaded([file("a.js", [simple]), file("a.test.js", [simple]), file("pnpm-lock.yaml", [simple]), file("docs/plans/x.md", [simple])]);
  assert.deepEqual(view.groups.map((g) => [g.section, g.files.map((f) => f.path)]), [
    ["review", ["a.js", "docs/plans/x.md"]],
    ["tests", ["a.test.js"]],
    ["generated", ["pnpm-lock.yaml"]],
  ]);
  assert.equal(view.reviewFiles.length, 2);
  assert.equal(view.setAsideCount, 2);
});

test("a repository's linguist-generated marks move files into generated", () => {
  const view = new DiffView();
  view.load({ files: [file("gen/a.ts", [simple])], gitAttributes: "gen/** linguist-generated" });
  assert.equal(view.groups[0].section, "generated");
});

test("review files start open unless already viewed; set-aside files start closed", () => {
  const view = loaded([file("a.js", [simple]), file("v.js", [simple], { viewed: "VIEWED" }), file("a.test.js", [simple])]);
  assert.equal(view.isCollapsed("a.js"), false);
  assert.equal(view.isCollapsed("v.js"), true);
  assert.equal(view.isCollapsed("a.test.js"), true);
});

test("toggling opens a set-aside file and closes a review one, and both are remembered across a scope change", () => {
  const view = loaded([file("a.js", [simple]), file("a.test.js", [simple])]);
  view.toggleCollapsed("a.test.js");
  view.toggleCollapsed("a.js");
  assert.deepEqual([view.isCollapsed("a.test.js"), view.isCollapsed("a.js")], [false, true]);
  assert.equal(view.rows.filter((r) => r.type === "line").length, 3); // only a.test.js shows lines
});

test("marking a file viewed collapses it, and unmarking opens it", () => {
  const view = loaded([file("a.js", [simple])]);
  view.setViewedLocally("a.js", true);
  assert.deepEqual([view.files[0].viewed, view.isCollapsed("a.js")], ["VIEWED", true]);
  view.setViewedLocally("a.js", false);
  assert.deepEqual([view.files[0].viewed, view.isCollapsed("a.js")], ["UNVIEWED", false]);
  assert.equal(view.viewedReviewCount, 0);
});

test("changing layout rebuilds the rows", () => {
  const view = loaded([file("a.js", [simple])]);
  assert.equal(view.rows[1].type, "hunkHeader");
  assert.equal(view.rows[2].type, "line");
  view.setLayout("split");
  assert.equal(view.rows[2].type, "pair");
});

test("a reload keeps nothing from the old diff's open/closed choices", () => {
  const view = loaded([file("a.js", [simple])]);
  view.toggleCollapsed("a.js");
  view.load(diff([file("a.js", [simple])]));
  assert.equal(view.isCollapsed("a.js"), false);
});

// ---- Find -------------------------------------------------------------------

test("find is case-insensitive, per side of a split row, and ignores headers", () => {
  const rows = buildRows([{ section: "review", files: [file("Needle.js", [hunk([line("removed", "A needle NEEDLE", 1), line("added", "needle", null, 1)], "needle ctx")])] }], "split", () => false);
  const matches = findMatches("needle", rows);
  assert.deepEqual(matches.map((m) => [m.row, m.column, m.start, m.end]), [[2, 0, 2, 8], [2, 0, 9, 15], [2, 1, 0, 6]]);
});

test("find in unified rows reports column 0, and blank queries find nothing", () => {
  const rows = buildRows([{ section: "review", files: [file("a.js", [hunk([line("added", "foo foo", null, 1)])])] }], "unified", () => false);
  assert.deepEqual(findMatches("foo", rows).map((m) => [m.row, m.column, m.start]), [[2, 0, 0], [2, 0, 4]]);
  assert.deepEqual(findMatches("   ", rows), []);
  assert.deepEqual(findMatches("", rows), []);
});

test("matches are literal text, so regex characters mean themselves", () => {
  const rows = buildRows([{ section: "review", files: [file("a.js", [hunk([line("added", "a.b a+b (x)", null, 1)])])] }], "unified", () => false);
  assert.equal(findMatches("a.b", rows).length, 1);
  assert.equal(findMatches("(x)", rows).length, 1);
  assert.equal(findMatches("a+b", rows).length, 1);
});

test("the view steps through matches and wraps around", () => {
  const view = loaded([file("a.js", [hunk([line("added", "x x x", null, 1)])])]);
  view.setFindQuery("x");
  assert.equal(view.findMatches.length, 3);
  assert.equal(view.currentFindIndex, 0);
  view.findNext(); view.findNext(); view.findNext();
  assert.equal(view.currentFindIndex, 0); // wrapped
  view.findPrevious();
  assert.equal(view.currentFindIndex, 2);
  view.setFindQuery("nothing");
  assert.equal(view.currentFindIndex, null);
  assert.equal(view.currentFindMatch, null);
});

test("reclassifying after a settings change keeps what the reviewer opened and closed", () => {
  const view = loaded([file("a.js", [simple]), file("a.test.js", [simple])]);
  view.toggleCollapsed("a.js");
  view.toggleCollapsed("a.test.js"); // opened
  view.reclassify({ patterns: { tests: [], generated: [], other: [] } }); // nothing is set aside any more
  assert.deepEqual(view.groups.map((g) => g.section), ["review"]);
  assert.equal(view.isCollapsed("a.js"), true);
  view.reclassify({ patterns: undefined, gitAttributes: "a.js linguist-generated" });
  assert.equal(view.groups.find((g) => g.files.some((f) => f.path === "a.js")).section, "generated");
});
