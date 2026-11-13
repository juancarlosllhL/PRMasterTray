import { test } from "node:test";
import assert from "node:assert/strict";
import { DiffView } from "../src/core/diffView.js";
import { diffPayload, fontFrom } from "../src/core/diffPayload.js";
import { sectionHeading } from "../src/core/fileScope.js";

const line = (kind, text) => ({ kind, text, oldNumber: 1, newNumber: 1, noNewlineAtEnd: false });
const file = (path, over = {}) => ({ path, previousPath: null, change: "modified", additions: 2, deletions: 1, content: { kind: "hunks", hunks: [{ oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, context: "", lines: [line("added", "needle")] }] }, viewed: "UNVIEWED", ...over });

const loaded = () => {
  const view = new DiffView();
  view.load({ files: [file("src/a.js"), file("src/b.js", { viewed: "VIEWED" }), file("a.test.js"), file("pnpm-lock.yaml")] });
  return view;
};
const base = (view, over = {}) => ({ meta: { title: "T", repo: "acme/w", number: 5, url: "https://github.com/acme/w/pull/5", kind: "review" }, phase: "loaded", error: null, viewedErrors: {}, view, isTruncated: false, canMerge: false, canApprove: true, settings: { diffFontFamily: null, diffFontSize: 12, diffLigatures: false }, description: null, ...over });

test("section headings carry their counts", () => {
  assert.equal(sectionHeading("tests", 12), "Tests · 12");
  assert.equal(sectionHeading("review", 3), "Review · 3");
});

test("the sidebar groups files by section with headings and per-file state", () => {
  const p = diffPayload(base(loaded()));
  assert.deepEqual(p.sidebar.map((g) => [g.section, g.heading, g.files.length]), [["review", "Review · 2", 2], ["tests", "Tests · 1", 1], ["generated", "Generated · 1", 1]]);
  const b = p.sidebar[0].files.find((f) => f.path === "src/b.js");
  assert.deepEqual({ viewed: b.viewed, collapsed: b.collapsed, additions: b.additions }, { viewed: true, collapsed: true, additions: 2 });
});

test("counts: viewed of review files, and how many are set aside", () => {
  assert.deepEqual(diffPayload(base(loaded())).counts, { viewed: 1, review: 2, setAside: 2 });
});

test("the rows are the view's, so the layout reaches the window", () => {
  const view = loaded();
  assert.equal(diffPayload(base(view)).layout, "unified");
  view.setLayout("split");
  const p = diffPayload(base(view));
  assert.equal(p.layout, "split");
  assert.ok(p.rows.some((r) => r.type === "pair"));
});

test("find state: the query, how many matches and which one is current", () => {
  const view = loaded();
  view.setFindQuery("needle");
  const p = diffPayload(base(view));
  assert.equal(p.find.query, "needle");
  assert.equal(p.find.total, view.findMatches.length);
  assert.equal(p.find.current, 0);
  view.setFindQuery("");
  assert.deepEqual(diffPayload(base(view)).find, { query: "", total: 0, current: null, matches: [] });
});

test("matches are shipped with their row, side and range so the window can mark them", () => {
  const view = loaded();
  view.setFindQuery("need");
  const [first] = diffPayload(base(view)).find.matches;
  assert.deepEqual(Object.keys(first).sort(), ["column", "end", "row", "start"]);
});

test("font settings become what the window needs; ligatures are off unless asked for", () => {
  assert.deepEqual(fontFrom({ diffFontFamily: null, diffFontSize: 12, diffLigatures: false }), { family: 'Consolas, "Cascadia Mono", monospace', size: 12, ligatures: false });
  assert.equal(fontFrom({ diffFontFamily: "Fira Code", diffFontSize: 14, diffLigatures: true }).family, '"Fira Code", Consolas, monospace');
  // A family name is data from a settings file and ends up in CSS: quotes are stripped.
  assert.equal(fontFrom({ diffFontFamily: 'x"; background: red; "', diffFontSize: 12, diffLigatures: false }).family.includes(";"), false);
});

test("before a diff has loaded the payload is still well-formed", () => {
  const p = diffPayload(base(new DiffView(), { phase: "loading", canApprove: false }));
  assert.deepEqual([p.rows, p.sidebar, p.counts], [[], [], { viewed: 0, review: 0, setAside: 0 }]);
});

// ---- Score ------------------------------------------------------------------

import { heat } from "../src/core/score.js";

const score = { available: true, requested: false, progress: null, stopped: null };

test("before Score is asked for the payload carries no heat, only whether it could be", () => {
  const p = diffPayload(base(loaded(), { score }));
  assert.deepEqual(p.score, { available: true, requested: false, progress: null, stopped: null });
  assert.deepEqual(p.heatMarks, []);
  assert.equal(p.sidebar[0].files[0].heat, null);
});

test("once shown, each file carries its heat state and the scroll track gets its marks", () => {
  const view = loaded();
  view.setScores("src/a.js", [{ block: heat(3, 1), lines: [heat(3, 1)] }]);
  view.setFileHeat("src/a.js", { state: "scored", level: 3 });
  view.setFileHeat("src/b.js", { state: "waiting" });
  view.setHeatShown(true);
  const p = diffPayload(base(view, { score: { ...score, requested: true } }));
  const files = Object.fromEntries(p.sidebar.flatMap((g) => g.files).map((f) => [f.path, f.heat]));
  assert.deepEqual(files["src/a.js"], { state: "scored", level: 3 });
  assert.deepEqual(files["src/b.js"], { state: "waiting" });
  assert.equal(p.heatMarks.length, 1);
  assert.equal(p.heatMarks[0].level, 3);
});
