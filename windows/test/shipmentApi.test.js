import { test } from "node:test";
import assert from "node:assert/strict";
import {
  containmentQuery,
  decodeContainment,
  decodeMerged,
  decodeReleases,
  fetchShipments,
} from "../src/core/github.js";

const mergedNode = (over = {}) => ({
  id: "PR_1",
  number: 5,
  title: "Add thing",
  url: "https://github.com/acme/w/pull/5",
  mergedAt: "2026-10-29T10:00:00Z",
  repository: { id: "R_1", nameWithOwner: "acme/w", isPrivate: false },
  mergeCommit: {
    oid: "abc",
    statusCheckRollup: {
      state: "FAILURE",
      contexts: {
        nodes: [
          { __typename: "CheckRun", name: "CD", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "https://circleci.com/workflow/1" },
          { __typename: "StatusContext", context: "ci/job", state: "SUCCESS", targetUrl: "https://circleci.com/job/2" },
          { __typename: "Other" },
        ],
      },
    },
  },
  ...over,
});

test("merged PRs decode, normalising CheckRun and StatusContext to one shape", () => {
  const [m] = decodeMerged({ data: { merged: { nodes: [mergedNode(), {}] } } });
  assert.equal(m.repositoryID, "R_1");
  assert.equal(m.mergeCommitOid, "abc");
  assert.equal(m.rollupState, "FAILURE");
  assert.deepEqual(m.contexts, [
    { name: "CD", state: "FAILURE", url: "https://circleci.com/workflow/1", isWorkflow: true },
    { name: "ci/job", state: "SUCCESS", url: "https://circleci.com/job/2", isWorkflow: false },
  ]);
});

test("a merge whose commit GitHub has not materialised yet decodes with no oid", () => {
  const [m] = decodeMerged({ data: { merged: { nodes: [mergedNode({ mergeCommit: null })] } } });
  assert.equal(m.mergeCommitOid, null);
  assert.equal(m.rollupState, null);
  assert.deepEqual(m.contexts, []);
});

test("a CheckRun that has not completed is pending; cancelled and stale are failures", () => {
  const run = (status, conclusion) => ({ __typename: "CheckRun", name: "x", status, conclusion, detailsUrl: null });
  const states = [run("IN_PROGRESS", "SUCCESS"), run("COMPLETED", "CANCELLED"), run("COMPLETED", "STALE"), run("COMPLETED", "SKIPPED"), run("COMPLETED", "WHATEVER_NEW")].map(
    (c) => decodeMerged({ data: { merged: { nodes: [mergedNode({ mergeCommit: { oid: "a", statusCheckRollup: { state: "PENDING", contexts: { nodes: [c] } } } })] } } })[0].contexts[0].state,
  );
  assert.deepEqual(states, ["PENDING", "FAILURE", "FAILURE", "SUCCESS", "PENDING"]);
});

test("errors behind a 200 are not read as nothing merged", () => {
  assert.throws(() => decodeMerged({ errors: [{ message: "boom" }] }), /boom/);
});

test("releases decode keyed by repository, dropping drafts and non-commit tags", () => {
  const rel = (over) => ({ tagName: "v1", url: "https://github.com/acme/w/releases/tag/v1", createdAt: "2026-10-29T10:00:00Z", publishedAt: null, isDraft: false, tagCommit: { oid: "t" }, ...over });
  const out = decodeReleases({
    data: { nodes: [{ id: "R_1", releases: { nodes: [rel({}), rel({ tagName: "v2", isDraft: true }), rel({ tagName: "v3", tagCommit: null })] } }, null] },
  });
  assert.deepEqual(Object.keys(out), ["R_1"]);
  assert.deepEqual(out.R_1.map((r) => r.tagName), ["v1"]);
});

const candidate = (over = {}) => ({
  pr: { id: "PR_1", repo: "acme/w", mergeCommitOid: "abc" },
  release: { tagName: "v3.31.2" },
  ...over,
});

test("containment query binds every remote value as a variable, never into the document", () => {
  assert.equal(containmentQuery([]), null);
  const { query, variables } = containmentQuery([candidate()]);
  assert.deepEqual(variables, { owner0: "acme", name0: "w", tag0: "refs/tags/v3.31.2", oid0: "abc" });
  assert.doesNotMatch(query, /acme|v3\.31|abc/);
  assert.match(query, /t0: repository\(owner: \$owner0, name: \$name0\)/);
});

test("containment: behind and identical contain; ahead and diverged do not; unknown is left out", () => {
  const cs = ["behind", "identical", "ahead", "diverged", "future"].map((_, i) => candidate({ pr: { id: `PR_${i}`, repo: "acme/w", mergeCommitOid: "a" }, release: { tagName: "v1" } }));
  const node = (status) => ({ ref: { compare: { status } } });
  const out = decodeContainment(
    { data: { t0: node("BEHIND"), t1: node("IDENTICAL"), t2: node("AHEAD"), t3: node("DIVERGED"), t4: node("SOMETHING_NEW") } },
    cs,
  );
  assert.deepEqual([...out], [["PR_0|v1", true], ["PR_1|v1", true], ["PR_2|v1", false], ["PR_3|v1", false]]);
});

test("a candidate GitHub could not resolve is omitted, not recorded as not-contained", () => {
  const out = decodeContainment({ data: { t0: null } }, [candidate()]);
  assert.equal(out.size, 0);
});

test("fetchShipments makes no release or containment request when nothing merged", async () => {
  let calls = 0;
  const fetchImpl = async () => {
    calls++;
    return { ok: true, status: 200, json: async () => ({ data: { merged: { nodes: [] } } }) };
  };
  const out = await fetchShipments({ token: "t", fetchImpl, now: new Date("2026-10-30T10:00:00Z"), windowDays: 1 });
  assert.deepEqual(out, []);
  assert.equal(calls, 1);
});

test("with the merged window off, nothing is asked of GitHub", async () => {
  let calls = 0;
  const fetchImpl = async () => { calls++; return { ok: true, status: 200, json: async () => ({}) }; };
  assert.deepEqual(await fetchShipments({ token: "t", fetchImpl, now: new Date("2026-10-30T10:00:00Z"), windowDays: null }), []);
  assert.equal(calls, 0);
});
