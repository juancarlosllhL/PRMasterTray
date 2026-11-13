import { test } from "node:test";
import assert from "node:assert/strict";
import { candidates, isRecent, mergedQualifier, pickLink, resolve } from "../src/core/shipment.js";

const T = (iso) => new Date(iso);
const merge = (over = {}) => ({
  id: "PR_1",
  number: 5,
  title: "Add thing",
  url: "https://github.com/acme/w/pull/5",
  repo: "acme/w",
  repositoryID: "R_1",
  mergedAt: "2026-10-29T10:00:00Z",
  mergeCommitOid: "abc",
  rollupState: "SUCCESS",
  contexts: [],
  ...over,
});
const release = (tagName, cut, over = {}) => ({
  tagName,
  url: `https://github.com/acme/w/releases/tag/${tagName}`,
  tagCommitOid: "t",
  createdAt: cut,
  publishedAt: null,
  ...over,
});
const check = (over = {}) => ({ name: "CD", state: "SUCCESS", url: "https://circleci.com/job/1", isWorkflow: false, ...over });
const status = (m, releases = [], containment = new Map()) =>
  resolve({ merged: [m], releases: { R_1: releases }, containment })[0].status;

test("no merge commit yet is pending, not a failure", () => {
  assert.deepEqual(status(merge({ mergeCommitOid: null })), { kind: "pending" });
  assert.deepEqual(status(merge({ mergeCommitOid: "" })), { kind: "pending" });
});

test("a failing check is named, and links to its pipeline", () => {
  const s = status(merge({ rollupState: "FAILURE", contexts: [check({ name: "ci/build", state: "FAILURE", url: "https://circleci.com/job/9" })] }));
  assert.deepEqual(s, { kind: "failed", name: "ci/build", url: "https://circleci.com/job/9" });
});

test("a failure the rollup knows but no context names is still a failure", () => {
  assert.deepEqual(status(merge({ rollupState: "ERROR" })), { kind: "failed", name: "a check", url: "https://github.com/acme/w/pull/5" });
});

test("a named failing check outranks a green rollup", () => {
  const s = status(merge({ rollupState: "SUCCESS", contexts: [check({ state: "ERROR" })] }));
  assert.equal(s.kind, "failed");
});

test("running checks mean building", () => {
  assert.equal(status(merge({ rollupState: "PENDING", contexts: [check({ state: "PENDING" })] })).kind, "building");
  assert.equal(status(merge({ rollupState: "EXPECTED" })).kind, "building");
});

test("green with a containing release is released, in the earliest one", () => {
  const releases = [release("v1.2.0", "2026-10-29T13:00:00Z"), release("v1.1.0", "2026-10-29T11:00:00Z")];
  const containment = new Map([
    ["PR_1|v1.2.0", true],
    ["PR_1|v1.1.0", true],
  ]);
  const s = status(merge(), releases, containment);
  assert.deepEqual(s, { kind: "released", version: "v1.1.0", url: releases[1].url });
});

test("green, releases exist, none known to contain it: still building", () => {
  const releases = [release("v1.2.0", "2026-10-29T13:00:00Z")];
  assert.equal(status(merge(), releases, new Map()).kind, "building"); // unknown is not "no"
  assert.equal(status(merge(), releases, new Map([["PR_1|v1.2.0", false]])).kind, "building");
});

test("a repository that cuts no releases rests at pending", () => {
  assert.deepEqual(status(merge(), []), { kind: "pending" });
  assert.deepEqual(status(merge({ rollupState: null }), []), { kind: "pending" });
});

test("release time is publication, not the tag commit's date", () => {
  const r = release("v2", "2026-10-29T09:00:00Z", { publishedAt: "2026-10-29T12:00:00Z" });
  assert.equal(candidates([merge()], { R_1: [r] }).length, 1); // createdAt alone would predate the merge
});

test("candidates skip releases cut before the merge, and merges without a commit", () => {
  const before = release("v0", "2026-10-29T09:59:00Z");
  const after = release("v1", "2026-10-29T10:00:00Z");
  const c = candidates([merge(), merge({ id: "PR_2", mergeCommitOid: null })], { R_1: [before, after] });
  assert.deepEqual(c.map((x) => `${x.pr.id}|${x.release.tagName}`), ["PR_1|v1"]);
});

test("the workflow beats a single job; running beats failing", () => {
  const fallback = "https://github.com/acme/w/pull/5";
  const job = check({ url: "https://circleci.com/job/1", state: "PENDING" });
  const wfOk = check({ url: "https://circleci.com/workflow/ok", isWorkflow: true });
  const wfFail = check({ url: "https://circleci.com/workflow/bad", isWorkflow: true, state: "FAILURE" });
  assert.equal(pickLink([job, wfOk], fallback), "https://circleci.com/workflow/ok");
  assert.equal(pickLink([wfOk, wfFail], fallback), "https://circleci.com/workflow/bad");
  assert.equal(pickLink([check({ url: null })], fallback), fallback);
});

test("a merge is recent for the window, and a future-dated one still counts", () => {
  const now = T("2026-10-30T10:00:00Z");
  assert.equal(isRecent("2026-10-29T10:00:00Z", now, 1), true); // exactly one day: inclusive
  assert.equal(isRecent("2026-10-29T09:59:59Z", now, 1), false);
  assert.equal(isRecent("2026-10-31T00:00:00Z", now, 1), true); // clock trails GitHub's
  assert.equal(isRecent("2026-10-30T09:00:00Z", now, null), false); // off
});

test("the search qualifier is a full timestamp cut from the same window", () => {
  assert.equal(mergedQualifier(T("2026-10-30T10:00:00.456Z"), 1), "merged:>2026-10-29T10:00:00Z");
});

// ---- Environments (stg/prod chips) ----------------------------------------

import { unidentifiedVersions } from "../src/core/shipment.js";

const promoted = (environment, region, version) => ({ file: { environment, region }, version });
const envs = (promotions, releases, containment = new Map(), m = merge()) =>
  resolve({ merged: [m], releases: { R_1: releases }, containment, promotions: { "acme/w": promotions } })[0].environments;

test("an environment carries the change when its release contains the merge", () => {
  const r = release("v1.5.0", "2026-10-29T12:00:00Z");
  const out = envs([promoted("staging", "eu", "1.5.0")], [r], new Map([["PR_1|v1.5.0", true]]));
  assert.deepEqual(out, [{ environment: "staging", status: { kind: "carrying", version: "1.5.0" }, regionsAgree: true }]);
});

test("a release cut before the merge is settled by the clock alone: awaiting, no request needed", () => {
  const r = release("v1.4.0", "2026-10-29T09:00:00Z");
  assert.equal(envs([promoted("production", "eu", "1.4.0")], [r])[0].status.kind, "awaiting");
});

test("a higher version cut from another branch is not 'carrying' — only containment decides", () => {
  const r = release("v9.0.0", "2026-10-29T12:00:00Z");
  const out = envs([promoted("staging", "eu", "9.0.0")], [r], new Map([["PR_1|v9.0.0", false]]));
  assert.deepEqual(out[0].status, { kind: "awaiting", version: "9.0.0" });
});

test("no release matches the promoted version, or no answer yet: unknown, never a guess", () => {
  assert.equal(envs([promoted("staging", "eu", "7.7.7")], [release("v1.0.0", "2026-10-29T12:00:00Z")])[0].status.kind, "unknown");
  const r = release("v1.5.0", "2026-10-29T12:00:00Z");
  assert.equal(envs([promoted("staging", "eu", "1.5.0")], [r], new Map())[0].status.kind, "unknown");
});

test("every region must carry it; a region proven to lack it settles the environment over an unknown", () => {
  const has = release("v2.0.0", "2026-10-29T12:00:00Z");
  const lacks = release("v1.0.0", "2026-10-29T08:00:00Z");
  const containment = new Map([["PR_1|v2.0.0", true]]);

  const mixed = envs([promoted("staging", "eu", "2.0.0"), promoted("staging", "us", "1.0.0")], [has, lacks], containment);
  assert.deepEqual(mixed[0], { environment: "staging", status: { kind: "awaiting", version: "1.0.0" }, regionsAgree: false });

  const unanswered = envs([promoted("staging", "eu", "2.0.0"), promoted("staging", "us", "3.0.0")], [has], containment);
  assert.equal(unanswered[0].status.kind, "unknown"); // an unknown is never rounded into a yes
});

test("staging comes first and only environments with a promotion appear", () => {
  const r = release("v1.5.0", "2026-10-29T12:00:00Z");
  const out = envs([promoted("production", "eu", "1.5.0"), promoted("staging", "eu", "1.5.0")], [r]);
  assert.deepEqual(out.map((e) => e.environment), ["staging", "production"]);
  assert.deepEqual(envs([], [r]), []);
});

test("versions no fetched release accounts for are asked for by name, once per repo and version", () => {
  const known = release("v1.0.0", "2026-10-29T12:00:00Z");
  const merged = [merge(), merge({ id: "PR_2" })];
  const out = unidentifiedVersions(merged, { R_1: [known] }, {
    "acme/w": [promoted("staging", "eu", "1.0.0"), promoted("production", "eu", "0.9.0"), promoted("production", "us", "0.9.0")],
  });
  assert.deepEqual(out, [{ repo: "acme/w", repositoryID: "R_1", version: "0.9.0" }]);
});
