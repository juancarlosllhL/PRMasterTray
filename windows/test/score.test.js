import { test } from "node:test";
import assert from "node:assert/strict";
import { ScoreError, createJevClient, diffBlocks, heat, importanceOf, jevBatches, jevScores, levelOfBlockScore, lineHeatOf, parseEndpoint, VERIFICATION } from "../src/core/score.js";

// ---- Importance -------------------------------------------------------------

test("the score rounds to the nearest of four levels, clamped; a non-finite one is sensitive", () => {
  assert.deepEqual([0, 0.49, 0.5, 1.4, 2.5, 3, 9, -2].map(importanceOf), [0, 0, 1, 1, 3, 3, 3, 0]);
  assert.equal(importanceOf(NaN), 3);
  assert.equal(importanceOf(Infinity), 3);
});

test("heat clamps its score and is uncertain only below 0.35 confidence; unknown confidence is trusted", () => {
  assert.equal(heat(7, 1).score, 3);
  assert.equal(heat(NaN, 1).score, 3);
  assert.equal(heat(1, 0.34).uncertain, true);
  assert.equal(heat(1, 0.35).uncertain, false);
  assert.equal(heat(1, null).uncertain, false);
  assert.equal(heat(2.2, 0.9).level, 2);
});

test("a block's score gives each changed line its own heat, or the block's where it had none", () => {
  const score = { block: heat(1, 1), lines: [heat(3, 1), null] };
  assert.equal(lineHeatOf(score, 0).level, 3);
  assert.equal(lineHeatOf(score, 1).level, 1); // no answer of its own: the block's
  assert.equal(lineHeatOf(score, 9).level, 1); // beyond the lines it knows
});

test("a file's level is its hottest drawn line, so the sidebar never undersells it", () => {
  assert.equal(levelOfBlockScore({ block: heat(0, 1), lines: [heat(3, 1), heat(0, 1)] }), 3);
  // Not every line answered: the block's own answer is drawn on the rest.
  assert.equal(levelOfBlockScore({ block: heat(2, 1), lines: [heat(0, 1), null] }), 2);
  assert.equal(levelOfBlockScore({ block: heat(1, 1), lines: [] }), 1);
});

// ---- Blocks -----------------------------------------------------------------

const line = (kind, text) => ({ kind, text, oldNumber: 1, newNumber: 1, noNewlineAtEnd: false });
const fileOf = (lines, context = "fn()") => ({ path: "a.go", content: { kind: "hunks", hunks: [{ oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, context, lines }] } });

test("a block is an unbroken run of changed lines, with a few lines of context either side", () => {
  const f = fileOf([
    line("context", "c1"), line("context", "c2"), line("context", "c3"), line("context", "c4"),
    line("removed", "old"), line("added", "new"),
    line("context", "c5"), line("context", "c6"), line("context", "c7"), line("context", "c8"),
  ]);
  const [b] = diffBlocks(f);
  assert.deepEqual([b.hunk, b.start, b.end], [0, 4, 6]);
  assert.deepEqual(b.changed, ["-old", "+new"]);
  assert.deepEqual(b.before, ["c2", "c3", "c4"]); // three, nearest first read in order
  assert.deepEqual(b.after, ["c5", "c6", "c7"]);
  assert.equal(b.declaration, "fn()");
  assert.deepEqual(b.key, { path: "a.go", text: "-old\n+new" });
});

test("context stops at the next change: that change is its own block", () => {
  const blocks = diffBlocks(fileOf([line("added", "a"), line("context", "x"), line("added", "b")]));
  assert.equal(blocks.length, 2);
  assert.deepEqual(blocks[0].after, ["x"]);
  assert.deepEqual(blocks[1].before, ["x"]);
});

test("a file with no hunks has no blocks", () => {
  assert.deepEqual(diffBlocks({ path: "x", content: { kind: "omitted", reason: "tooLarge" } }), []);
  assert.deepEqual(diffBlocks(fileOf([line("context", "only")])), []);
});

// ---- The request ------------------------------------------------------------

const blockWith = (...changed) => diffBlocks(fileOf(changed.map((t) => line("added", t))))[0];

test("blocks are named b<position> and their changed lines tagged [l<offset>], with a question each", () => {
  const { batches, tooLarge } = jevBatches("a.go", [blockWith("x := 1", "}")]);
  assert.deepEqual(tooLarge, []);
  const { body } = batches[0];
  assert.equal(body.model, "typesafe/jev-1.13");
  assert.deepEqual(body.provider, { data_collection: "deny" }); // changed lines are never kept by the provider
  assert.equal(body.state.path, "a.go");
  assert.match(body.state.blocks.b0, /^In fn\(\)\n\[l0\] \+x := 1\n\[l1\] \+\}$/);
  assert.deepEqual(Object.keys(body.questions).sort(), ["b0", "b0_l0"]); // "}" says nothing on its own: no question
  assert.equal(body.questions.b0.type, "score");
  assert.equal(body.questions.b0.criteria.length, 4);
  assert.match(body.questions.b0_l0.instructions, /\[l0\]/);
});

test("long lines are cut before they are sent", () => {
  const { batches } = jevBatches("a.go", [blockWith("x".repeat(900))]);
  assert.ok(batches[0].body.state.blocks.b0.split("\n").at(-1).length <= 520);
});

test("a block too big for the model is reported, not sent; the rest still go", () => {
  const huge = blockWith(...Array.from({ length: 200 }, () => "y".repeat(500)));
  const { batches, tooLarge } = jevBatches("a.go", [blockWith("ok := true"), huge]);
  assert.deepEqual(tooLarge, [1]);
  assert.deepEqual(batches.flatMap((b) => b.blocks), [0]);
});

test("blocks are split across requests so none outgrows the model's limits", () => {
  const big = () => blockWith(...Array.from({ length: 70 }, () => "z".repeat(500))); // about 11,700 tokens of state each
  const { batches } = jevBatches("a.go", [big(), big(), big()]);
  assert.deepEqual(batches.map((b) => b.blocks), [[0, 1], [2]]);
});

// ---- The answer -------------------------------------------------------------

test("answers are matched back to blocks and lines by their keys", () => {
  const { batches } = jevBatches("a.go", [blockWith("a := 1", "b := 2")]);
  const answers = { b0: { score: 1, confidence: 0.9 }, b0_l0: { score: 3, confidence: 0.8 }, b0_l1: { score: 0.2, confidence: 0.1 } };
  const scores = jevScores({ answers }, batches[0]);
  assert.equal(scores[0].block.level, 1);
  assert.deepEqual(scores[0].lines.map((h) => h.level), [3, 0]);
  assert.equal(scores[0].lines[1].uncertain, true);
});

test("with no block answer the hottest line speaks for the block; with none at all there is no score", () => {
  const { batches } = jevBatches("a.go", [blockWith("a := 1"), blockWith("b := 2")]);
  const scores = jevScores({ answers: { b0_l0: { score: 2, confidence: 1 } } }, batches[0]);
  assert.equal(scores[0].block.level, 2);
  assert.equal(1 in scores, false);
});

test("an answer in the wrong shape is refused", () => {
  const { batches } = jevBatches("a.go", [blockWith("a := 1")]);
  assert.throws(() => jevScores({ nope: 1 }, batches[0]), /answer/i);
});

// ---- Where requests go ------------------------------------------------------

test("blank means OpenRouter; the key is sent wherever this points, so nothing that could leak it passes", () => {
  assert.equal(parseEndpoint("").isDefault, true);
  assert.equal(parseEndpoint("   ").systemOne, "https://openrouter.ai/api/v1/systemone");
  assert.equal(parseEndpoint("https://proxy.example/api/v1/").systemOne, "https://proxy.example/api/v1/systemone");
  assert.equal(parseEndpoint("http://localhost:8080/v1").isDefault, false); // plain http only for loopback
  for (const bad of ["not a url", "http://proxy.example/v1", "https://user:pw@proxy.example/v1", "https://proxy.example/v1?x=1", "https://proxy.example/v1#frag", "ftp://x/y", "https://"]) {
    assert.throws(() => parseEndpoint(bad), Error, bad);
  }
});

// ---- The client -------------------------------------------------------------

const respond = (status, json = {}, headers = {}) => async (url, init) => ({ ok: status === 200, status, headers: { get: (k) => headers[k.toLowerCase()] ?? null }, json: async () => json, sent: { url, init } });

function client(fetchImpl) {
  return createJevClient({ token: "key", endpoint: parseEndpoint(""), fetchImpl });
}

test("a request carries the key, as JSON, from PRMaster", async () => {
  let seen;
  const fetchImpl = async (url, init) => { seen = { url, init }; return { ok: true, status: 200, headers: { get: () => null }, json: async () => ({ answers: { b0: { score: 1, confidence: 1 } } }) }; };
  const out = await client(fetchImpl).score("a.go", [blockWith("a := 1")]);
  assert.equal(seen.url, "https://openrouter.ai/api/v1/systemone");
  assert.deepEqual([seen.init.headers.Authorization, seen.init.headers["Content-Type"], seen.init.headers["User-Agent"]], ["Bearer key", "application/json", "PRMaster"]);
  assert.equal(JSON.parse(seen.init.body).model, "typesafe/jev-1.13");
  assert.equal(out.blocks[0].block.level, 1);
  assert.equal(out.tooLarge, false);
});

test("what the provider says maps to what the window can do about it", async () => {
  const code = async (status, headers) => {
    try {
      await client(respond(status, {}, headers)).score("a.go", [blockWith("a := 1")]);
    } catch (e) {
      assert.ok(e instanceof ScoreError);
      return e;
    }
    throw new Error("expected a failure");
  };
  assert.equal((await code(401)).code, "unauthorized");
  assert.equal((await code(403)).code, "unauthorized");
  assert.equal((await code(402)).code, "noCredits");
  assert.equal((await code(503)).code, "unavailable");
  assert.equal((await code(418)).code, "refused");
  const limited = await code(429, { "retry-after": "7" });
  assert.deepEqual([limited.code, limited.retryAfterMs], ["rateLimited", 7000]);
  assert.equal((await code(429)).retryAfterMs, 10_000); // no header: a fallback wait
});

test("a network failure is the provider being unavailable, and a body that is not an answer is refused", async () => {
  await assert.rejects(client(async () => { throw new TypeError("fetch failed"); }).score("a", [blockWith("a := 1")]), { code: "unavailable" });
  await assert.rejects(client(respond(200, { nope: 1 })).score("a", [blockWith("a := 1")]), { code: "refused" });
});

test("a block that was too large is flagged on the result", async () => {
  const huge = blockWith(...Array.from({ length: 200 }, () => "y".repeat(500)));
  const out = await client(respond(200, { answers: { b0: { score: 1, confidence: 1 } } })).score("a.go", [blockWith("a := 1"), huge]);
  assert.equal(out.tooLarge, true);
  assert.equal(out.blocks[1], null);
});

test("verification asks one tiny question: a 200 alone proves nothing behind a proxy's sign-in page", async () => {
  const ok = respond(200, { answers: { ok: { type: "noul", noul: 0.9 } } });
  await client(ok).verify();
  await assert.rejects(client(respond(200, "<html>sign in</html>")).verify(), /not a Jev answer/);
  assert.equal(VERIFICATION.questions.ok.type, "noul");
  assert.deepEqual(VERIFICATION.provider, { data_collection: "deny" });
});
