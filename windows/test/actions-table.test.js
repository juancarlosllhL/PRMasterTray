import { test } from "node:test";
import assert from "node:assert/strict";
import { ACTIONS } from "../src/core/actions.js";

const row = { number: 7, repo: "acme/w", title: "Fix it", readiness: "ready", stale: false };

test("merge is offered only for a ready pull request", () => {
  assert.equal(ACTIONS.merge.allowed(row), true);
  assert.equal(ACTIONS.merge.allowed({ ...row, readiness: "blocked" }), false);
});

test("close is offered only for a stale one", () => {
  assert.equal(ACTIONS.close.allowed({ ...row, stale: true }), true);
  assert.equal(ACTIONS.close.allowed(row), false);
});

test("every action's confirmation names the pull request and has a button", () => {
  for (const kind of Object.keys(ACTIONS)) {
    const p = ACTIONS[kind].prompt(row);
    assert.match(p.message, /#7/, kind);
    assert.equal(p.detail, "acme/w\nFix it", kind);
    assert.ok(p.button.length > 0, kind);
  }
});

test("running an action sends the head commit of the snapshot the user saw", async () => {
  const sent = [];
  const fetchImpl = async (url, init) => {
    sent.push(JSON.parse(init.body).variables);
    return { ok: true, status: 200, json: async () => ({ data: { mergePullRequest: { pullRequest: { merged: true } } } }) };
  };
  await ACTIONS.merge.run({ token: "t", fetchImpl }, { id: "PR_1", headRefOid: "abc" });
  assert.deepEqual(sent[0], { id: "PR_1", oid: "abc" });
});
