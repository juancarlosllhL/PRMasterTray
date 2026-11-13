import { test } from "node:test";
import assert from "node:assert/strict";
import { Worker } from "node:worker_threads";
import { createWorkerClient } from "../src/core/workerClient.js";
import { highlightFile } from "../src/core/highlight.js";

// The real Shiki worker, not a stand-in.
const worker = new Worker(new URL("../src/highlightWorker.js", import.meta.url));
const client = createWorkerClient(worker);
test.after(() => worker.terminate());

const highlight = async (segments, language, theme) => (await client.request({ segments, language, theme })).json;

test("a file is coloured through the worker, off the calling thread", async () => {
  const file = { path: "a.go", content: { kind: "hunks", hunks: [{ oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, context: "", lines: [{ kind: "added", text: "package main", oldNumber: null, newNumber: 1, noNewlineAtEnd: false }] }] } };
  const out = await highlightFile(file, "github-dark-default", highlight);
  assert.ok(out.content.hunks[0].lines[0].spans.some((s) => s.colour));
});

test("concurrent requests each get their own answer", async () => {
  const [a, b] = await Promise.all([
    client.request({ segments: [["const a = 1;"]], language: "typescript", theme: "github-dark-default" }),
    client.request({ segments: [["package main"]], language: "go", theme: "github-light-default" }),
  ]);
  assert.notEqual(a.json, b.json);
  assert.equal(client.pending, 0);
});

test("a worker error comes back as a rejection for that request only", async () => {
  await assert.rejects(client.request({ segments: [["x"]], language: "no-such-language", theme: "github-dark-default" }));
  const ok = await client.request({ segments: [["const a = 1;"]], language: "typescript", theme: "github-dark-default" });
  assert.ok(ok.json);
});

test("if the worker dies, waiting requests fail instead of hanging forever", async () => {
  const doomed = new Worker("process.exit(3)", { eval: true });
  const dying = createWorkerClient(doomed);
  await assert.rejects(dying.request({}), /exited|exit/);
});
