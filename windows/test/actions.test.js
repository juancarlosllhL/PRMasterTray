import { test } from "node:test";
import assert from "node:assert/strict";
import { approvePullRequest, closePullRequest, squashMerge, updateBranch } from "../src/core/github.js";

function recording(data) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push(JSON.parse(init.body));
    return { ok: true, status: 200, json: async () => data };
  };
  return { calls, fetchImpl };
}

test("squashMerge pins the merge to the head commit the user saw", async () => {
  const { calls, fetchImpl } = recording({ data: { mergePullRequest: { pullRequest: { merged: true } } } });
  await squashMerge({ token: "t", fetchImpl, id: "PR_1", expectedHeadOid: "abc" });
  assert.deepEqual(calls[0].variables, { id: "PR_1", oid: "abc" });
  assert.match(calls[0].query, /expectedHeadOid: \$oid/);
  assert.match(calls[0].query, /mergeMethod: SQUASH/);
});

test("squashMerge fails unless GitHub says merged", async () => {
  const { fetchImpl } = recording({ data: { mergePullRequest: { pullRequest: { merged: false } } } });
  await assert.rejects(squashMerge({ token: "t", fetchImpl, id: "x", expectedHeadOid: "y" }), /not merged/);
});

test("squashMerge surfaces GitHub's own refusal verbatim", async () => {
  const { fetchImpl } = recording({ errors: [{ message: "Head branch was modified" }] });
  await assert.rejects(squashMerge({ token: "t", fetchImpl, id: "x", expectedHeadOid: "y" }), /Head branch was modified/);
});

test("closePullRequest trusts only the returned state", async () => {
  const closed = recording({ data: { closePullRequest: { pullRequest: { id: "x", state: "CLOSED" } } } });
  await closePullRequest({ token: "t", fetchImpl: closed.fetchImpl, id: "x" });
  assert.deepEqual(closed.calls[0].variables, { id: "x" });

  const open = recording({ data: { closePullRequest: { pullRequest: { id: "x", state: "OPEN" } } } });
  await assert.rejects(closePullRequest({ token: "t", fetchImpl: open.fetchImpl, id: "x" }), /not closed/);
});

test("updateBranch merges base in, never rebases, and is pinned to the head oid", async () => {
  const { calls, fetchImpl } = recording({ data: { updatePullRequestBranch: { pullRequest: { id: "x", headRefOid: "new" } } } });
  await updateBranch({ token: "t", fetchImpl, id: "PR_1", expectedHeadOid: "abc" });
  assert.deepEqual(calls[0].variables, { id: "PR_1", oid: "abc" });
  assert.doesNotMatch(calls[0].query, /updateMethod/);
});

test("approve names the commit the reviewer read, and omits the body when there is none", async () => {
  const { calls, fetchImpl } = recording({ data: { addPullRequestReview: { pullRequestReview: { state: "APPROVED" } } } });
  await approvePullRequest({ token: "t", fetchImpl, id: "PR_1", commitOID: "abc" });
  assert.deepEqual(calls[0].variables, { id: "PR_1", oid: "abc" }); // omitted, not sent as null
  assert.match(calls[0].query, /event: APPROVE/);
  await approvePullRequest({ token: "t", fetchImpl, id: "PR_1", commitOID: "abc", body: "LGTM" });
  assert.deepEqual(calls[1].variables, { id: "PR_1", oid: "abc", body: "LGTM" });
});

test("approve trusts only the recorded review state: GitHub answers a declined review with a well-formed 200", async () => {
  const { fetchImpl } = recording({ data: { addPullRequestReview: { pullRequestReview: { state: "PENDING" } } } });
  await assert.rejects(approvePullRequest({ token: "t", fetchImpl, id: "x", commitOID: "y" }), /not recorded/);
  const refused = recording({ errors: [{ message: "Can not approve your own pull request" }] });
  await assert.rejects(approvePullRequest({ token: "t", fetchImpl: refused.fetchImpl, id: "x", commitOID: "y" }), /own pull request/);
});
