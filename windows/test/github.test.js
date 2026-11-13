import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeOpenPullRequests, fetchMyPullRequests } from "../src/core/github.js";
import { readToken } from "../src/core/token.js";

const node = (over = {}) => ({
  id: "PR_1",
  number: 7,
  title: "Add thing",
  url: "https://github.com/acme/widget/pull/7",
  isDraft: false,
  headRefOid: "abc123",
  updatedAt: "2026-10-01T10:00:00Z",
  createdAt: "2026-09-01T10:00:00Z",
  mergeable: "MERGEABLE",
  mergeStateStatus: "CLEAN",
  reviewDecision: "APPROVED",
  repository: { nameWithOwner: "acme/widget", isPrivate: true },
  commits: { nodes: [{ commit: { statusCheckRollup: { state: "SUCCESS" } } }] },
  reviews: { totalCount: 2 },
  ...over,
});

test("decodes a pull request node into the app's shape", () => {
  const [p] = decodeOpenPullRequests({ data: { open: { nodes: [node()] } } });
  assert.equal(p.repo, "acme/widget");
  assert.equal(p.mergeState, "CLEAN");
  assert.equal(p.checks, "SUCCESS");
  assert.equal(p.approvals, 2);
  assert.equal(p.readiness, "ready");
});

test("no CI means checks is null, and non-PR search hits are skipped", () => {
  const nodes = [node({ commits: { nodes: [{ commit: { statusCheckRollup: null } }] } }), {}];
  const result = decodeOpenPullRequests({ data: { open: { nodes } } });
  assert.equal(result.length, 1);
  assert.equal(result[0].checks, null);
});

test("GraphQL errors surface instead of an empty list", () => {
  assert.throws(
    () => decodeOpenPullRequests({ errors: [{ message: "Bad credentials" }] }),
    /Bad credentials/,
  );
});

test("fetchMyPullRequests sends the token as a bearer header", async () => {
  let seen;
  const fetchImpl = async (url, init) => {
    seen = { url, init };
    return { ok: true, status: 200, json: async () => ({ data: { open: { nodes: [node()] } } }) };
  };
  const prs = await fetchMyPullRequests({ token: "tok", fetchImpl });
  assert.equal(seen.url, "https://api.github.com/graphql");
  assert.equal(seen.init.headers.Authorization, "Bearer tok");
  assert.equal(prs.length, 1);
});

test("fetchMyPullRequests reports non-2xx", async () => {
  const fetchImpl = async () => ({ ok: false, status: 401, json: async () => ({}) });
  await assert.rejects(fetchMyPullRequests({ token: "t", fetchImpl }), /401/);
});

test("token: trims gh output, never echoes it in errors", async () => {
  assert.equal(await readToken({ run: async () => ({ stdout: " ghp_x\n", exitCode: 0 }) }), "ghp_x");
  await assert.rejects(
    readToken({ run: async () => ({ stdout: "ghp_secret", exitCode: 1 }) }),
    (e) => /exited with code 1/.test(e.message) && !e.message.includes("ghp_secret"),
  );
  await assert.rejects(readToken({ run: async () => ({ stdout: "  ", exitCode: 0 }) }), /no output/);
});
