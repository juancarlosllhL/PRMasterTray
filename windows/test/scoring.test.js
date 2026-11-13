import { test } from "node:test";
import assert from "node:assert/strict";
import { TOO_LARGE_MESSAGE, heatMarks, prepareScoring, scoreFiles, applyHeat } from "../src/core/scoring.js";
import { ScoreError, heat } from "../src/core/score.js";
import { DiffView } from "../src/core/diffView.js";

const line = (kind, text) => ({ kind, text, oldNumber: 1, newNumber: 1, noNewlineAtEnd: false });
const file = (path, ...changed) => ({ path, previousPath: null, change: "modified", additions: changed.length, deletions: 0, viewed: "UNVIEWED", content: { kind: "hunks", hunks: [{ oldStart: 1, oldCount: 1, newStart: 1, newCount: changed.length, context: "", lines: changed.map((t) => line("added", t)) }] } });
const scoreOf = (level) => ({ block: heat(level, 1), lines: [heat(level, 1)] });

// A client that answers every block with a fixed level, and counts what it was asked.
function fakeClient(level = 1, over = {}) {
  const calls = [];
  return { calls, async score(path, blocks) { calls.push(path); return over.score ? over.score(path, blocks, calls.length) : { blocks: blocks.map(() => scoreOf(level)), tooLarge: false }; } };
}
const run = (args) => {
  const results = new Map();
  const stops = [];
  const sleeps = [];
  return scoreFiles({ cache: new Map(), concurrency: 2, retryDelayMs: 50, sleep: async (ms) => { sleeps.push(ms); }, isCancelled: () => false, onFile: (p, r) => results.set(p, r), onStop: (m) => stops.push(m), ...args })
    .then(() => ({ results, stops, sleeps }));
};

test("prepared state: files whose blocks are all remembered are scored at once, the rest wait", () => {
  const cache = new Map();
  const a = file("a.go", "x := 1");
  const b = file("b.go", "y := 2");
  const first = prepareScoring([a, b], cache);
  assert.deepEqual([first.heat.get("a.go").state, first.heat.get("b.go").state], ["waiting", "waiting"]);
  cache.set(`a.go\0+x := 1`, scoreOf(2));
  const second = prepareScoring([a, b], cache);
  assert.deepEqual([second.heat.get("a.go").state, second.heat.get("a.go").level, second.heat.get("b.go").state], ["scored", 2, "waiting"]);
  assert.equal(prepareScoring([file("c.go")], cache).heat.has("c.go"), false); // nothing changed: nothing to score
});

test("each file is scored and remembered by the change it carries", async () => {
  const client = fakeClient(2);
  const cache = new Map();
  const { results } = await run({ files: [file("a.go", "x := 1"), file("b.go", "y := 2")], client, cache });
  assert.deepEqual([...results.values()].map((r) => [r.state, r.level]), [["scored", 2], ["scored", 2]]);
  assert.equal(cache.size, 2);
});

test("after a push only the blocks that changed are paid for again", async () => {
  const cache = new Map();
  const files = [file("a.go", "x := 1"), file("b.go", "y := 2")];
  await run({ files, client: fakeClient(), cache });
  const client = fakeClient();
  await run({ files: [file("a.go", "x := 1"), file("b.go", "y := 3")], client, cache });
  assert.deepEqual(client.calls, ["b.go"]);
});

test("a rate limit is waited out as long as asked, then the same file is tried again", async () => {
  let attempt = 0;
  const client = fakeClient(1, { score: async (p, blocks) => { if (++attempt === 1) throw new ScoreError("rateLimited", "slow down", { retryAfterMs: 7000 }); return { blocks: blocks.map(() => scoreOf(1)), tooLarge: false }; } });
  const { results, sleeps } = await run({ files: [file("a.go", "x := 1")], client });
  assert.deepEqual(sleeps, [7000]);
  assert.equal(results.get("a.go").state, "scored");
});

test("a stumbling provider gets one more try, then that file fails and the others carry on", async () => {
  const client = fakeClient(1, { score: async (p, blocks) => { if (p === "bad.go") throw new ScoreError("unavailable", "HTTP 503"); return { blocks: blocks.map(() => scoreOf(1)), tooLarge: false }; } });
  const { results, sleeps } = await run({ files: [file("bad.go", "a := 1"), file("good.go", "b := 2")], client, concurrency: 1 });
  assert.deepEqual(sleeps, [50]); // one retry delay
  assert.deepEqual([results.get("bad.go").state, results.get("bad.go").message, results.get("good.go").state], ["failed", "HTTP 503", "scored"]);
  assert.equal(client.calls.filter((p) => p === "bad.go").length, 2);
});

test("a refused key or an empty account stops everything: every waiting file is told why", async () => {
  for (const code of ["unauthorized", "noCredits"]) {
    const client = fakeClient(1, { score: async () => { throw new ScoreError(code, "stop here"); } });
    const { results, stops } = await run({ files: [file("a.go", "a := 1"), file("b.go", "b := 2"), file("c.go", "c := 3")], client, concurrency: 1 });
    assert.deepEqual(stops, ["stop here"], code);
    assert.deepEqual([...results.values()].map((r) => [r.state, r.message]), [["failed", "stop here"], ["failed", "stop here"], ["failed", "stop here"]], code);
    assert.equal(client.calls.length, 1, code); // no more requests once it is hopeless
  }
});

test("a block too large to send marks its file, but the scores that came back are kept", async () => {
  const client = fakeClient(1, { score: async (p, blocks) => ({ blocks: [scoreOf(3), null], tooLarge: true }) });
  const cache = new Map();
  const { results } = await run({ files: [file("a.go", "x := 1")], client, cache });
  assert.deepEqual([results.get("a.go").state, results.get("a.go").message], ["failed", TOO_LARGE_MESSAGE]);
  assert.equal(cache.size, 1);
});

test("cancelling stops after the files already in flight", async () => {
  let cancelled = false;
  const client = fakeClient(1, { score: async (p, blocks) => { cancelled = true; return { blocks: blocks.map(() => scoreOf(1)), tooLarge: false }; } });
  const { results } = await run({ files: [file("a.go", "a := 1"), file("b.go", "b := 2"), file("c.go", "c := 3")], client, concurrency: 1, isCancelled: () => cancelled });
  assert.deepEqual([...results.keys()], ["a.go"]);
});

test("no more files are in flight at once than the concurrency allows", async () => {
  let inFlight = 0;
  let peak = 0;
  const client = fakeClient(1, { score: async (p, blocks) => { peak = Math.max(peak, ++inFlight); await new Promise((r) => setImmediate(r)); inFlight--; return { blocks: blocks.map(() => scoreOf(1)), tooLarge: false }; } });
  await run({ files: Array.from({ length: 8 }, (_, i) => file(`f${i}.go`, `v := ${i}`)), client, concurrency: 3 });
  assert.equal(peak, 3);
});

test("the file the reviewer is looking at is scored first", async () => {
  const client = fakeClient();
  await run({ files: [file("a.go", "a := 1"), file("b.go", "b := 2"), file("c.go", "c := 3")], client, concurrency: 1, priorityPath: "c.go" });
  assert.deepEqual(client.calls, ["c.go", "a.go", "b.go"]);
});

// ---- Showing the scores -----------------------------------------------------

test("heat reaches each changed line of the file, from the score of its block", () => {
  const f = file("a.go", "one", "two");
  const scored = applyHeat(f, [{ block: heat(1, 1), lines: [heat(3, 1), null] }]);
  const lines = scored.content.hunks[0].lines;
  assert.deepEqual(lines.map((l) => l.heat.level), [3, 1]); // the second takes its block's answer
  assert.equal(f.content.hunks[0].lines[0].heat, undefined); // the loaded diff is never written into
});

test("a block with no score leaves its lines uncoloured", () => {
  const scored = applyHeat(file("a.go", "one"), [null]);
  assert.equal(scored.content.hunks[0].lines[0].heat, undefined);
});

test("the view shows heat only once the reviewer asked for it, and drops it when switched off", () => {
  const view = new DiffView();
  view.load({ files: [file("a.go", "one")] });
  view.setScores("a.go", [scoreOf(3)]);
  const heated = () => view.rows.find((r) => r.type === "line").line.heat;
  assert.equal(heated(), undefined); // scored, but not requested
  view.setHeatShown(true);
  assert.equal(heated().level, 3);
  view.setHeatShown(false);
  assert.equal(heated(), undefined);
});

test("marks on the scroll track: one per unbroken run of business logic or sensitive rows", () => {
  const row = (level) => ({ type: "line", line: { heat: level === null ? undefined : { level } } });
  const rows = [row(0), row(2), row(3), row(1), row(3), row(null), row(2)];
  assert.deepEqual(heatMarks(rows), [
    { row: 1, fraction: 1 / 7, level: 3 },
    { row: 4, fraction: 4 / 7, level: 3 },
    { row: 6, fraction: 6 / 7, level: 2 },
  ]);
  assert.deepEqual(heatMarks([row(0), row(1)]), []);
});

test("split rows count the hotter side", () => {
  const pair = (l, r) => ({ type: "pair", left: l === null ? null : { heat: { level: l } }, right: r === null ? null : { heat: { level: r } } });
  assert.deepEqual(heatMarks([pair(null, 2), pair(3, 0)]), [{ row: 0, fraction: 0, level: 3 }]);
});
