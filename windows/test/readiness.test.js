import { test } from "node:test";
import assert from "node:assert/strict";
import { evaluate } from "../src/core/readiness.js";

const pr = (over = {}) => ({
  isDraft: false,
  mergeable: "MERGEABLE",
  mergeState: "CLEAN",
  checks: "SUCCESS",
  threads: null,
  ...over,
});

test("draft outranks every other condition", () => {
  assert.equal(evaluate(pr({ isDraft: true, mergeable: "CONFLICTING", checks: "FAILURE" })), "draft");
});

test("conflicts outrank check results", () => {
  assert.equal(evaluate(pr({ mergeable: "CONFLICTING", checks: "FAILURE" })), "conflicted");
});

test("failing checks never read as merely blocked", () => {
  assert.equal(evaluate(pr({ checks: "FAILURE", mergeState: "BLOCKED" })), "checksFailing");
  assert.equal(evaluate(pr({ checks: "ERROR" })), "checksFailing");
});

test("running or expected checks are pending", () => {
  assert.equal(evaluate(pr({ checks: "PENDING" })), "checksPending");
  assert.equal(evaluate(pr({ checks: "EXPECTED" })), "checksPending");
});

test("a repo with no CI is not stuck pending", () => {
  assert.equal(evaluate(pr({ checks: null })), "ready");
});

test("clean, unstable and has-hooks are ready", () => {
  for (const mergeState of ["CLEAN", "UNSTABLE", "HAS_HOOKS"]) {
    assert.equal(evaluate(pr({ mergeState })), "ready");
  }
});

test("behind and unknown merge states", () => {
  assert.equal(evaluate(pr({ mergeState: "BEHIND" })), "behind");
  // Right after a push GitHub is still computing: calling it ready would notify on every push.
  assert.equal(evaluate(pr({ mergeState: "UNKNOWN" })), "checksPending");
});

test("blocked splits by who opened the unresolved threads, quill first", () => {
  const threads = (unresolved, unresolvedByQuill) => ({ unresolved, unresolvedByQuill });
  assert.equal(evaluate(pr({ mergeState: "BLOCKED", threads: threads(3, 1) })), "quillComments");
  assert.equal(evaluate(pr({ mergeState: "DIRTY", threads: threads(2, 0) })), "unresolvedComments");
  assert.equal(evaluate(pr({ mergeState: "BLOCKED", threads: threads(0, 0) })), "blocked");
  assert.equal(evaluate(pr({ mergeState: "BLOCKED", threads: null })), "blocked");
});
