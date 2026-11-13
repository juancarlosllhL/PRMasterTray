import { test } from "node:test";
import assert from "node:assert/strict";
import { fetchShipments } from "../src/core/github.js";
import { newDeploymentsState } from "../src/core/deployments.js";

const NOW = new Date("2026-10-30T10:00:00Z");

// A GitHub that knows one merged PR, one release that contains it, and one
// deployments repo whose staging runs that release.
function fakeGitHub({ failDeployments = false } = {}) {
  const log = { rest: 0, circleci: 0, trees: 0, blobs: 0, tagReleases: 0 };
  const release = (tagName) => ({ tagName, url: `https://github.com/acme/w/releases/tag/${tagName}`, createdAt: "2026-10-30T09:30:00Z", publishedAt: "2026-10-30T09:35:00Z", isDraft: false, tagCommit: { oid: "t" } });
  const fetchImpl = async (url, init) => {
    const ok = (json) => ({ ok: true, status: 200, json: async () => json });
    if (url.startsWith("https://api.github.com/search/code")) {
      log.rest++;
      return ok({ items: [{ path: "chat/values.yaml", repository: { full_name: "acme/deploy" } }] });
    }
    const { query, variables } = JSON.parse(init.body);
    if (failDeployments && !query.includes("compare(headRef") && /\$expression|t0: repository|b0: repository|r0: repository/.test(query)) throw new Error("deployments unreachable");
    if (query.includes("search(query: $mergedQuery")) {
      return ok({ data: { merged: { nodes: [{ id: "PR_1", number: 5, title: "Add thing", url: "https://github.com/acme/w/pull/5", mergedAt: "2026-10-30T09:00:00Z", repository: { id: "R_1", nameWithOwner: "acme/w", isPrivate: false }, mergeCommit: { oid: "abc", statusCheckRollup: { state: "SUCCESS", contexts: { nodes: [] } } } }] } } });
    }
    if (query.includes("nodes(ids: $repoIds)")) return ok({ data: { nodes: [{ id: "R_1", releases: { nodes: [release("v1.5.0")] } }] } });
    if (query.includes("compare(headRef")) return ok({ data: { t0: { ref: { compare: { status: "BEHIND" } } } } });
    if (query.includes("$expression")) {
      const files = {
        "HEAD:.circleci/config.yml": () => (log.circleci++, "repository: lec-w\n"),
        "HEAD:chat/values.yaml": () => "appName: lec-w\n",
      };
      const text = files[variables.expression]?.() ?? null;
      return ok({ data: { repository: { object: text === null ? null : { text } } } });
    }
    if (/t0: repository/.test(query)) {
      log.trees++;
      return ok({ data: { t0: { object: { entries: [{ name: "kargo", object: { oid: "k" } }, { name: "values.stg.eu.yaml", object: { oid: "s" } }] } } } });
    }
    if (/b0: repository/.test(query)) {
      log.blobs++;
      return ok({ data: { b0: { object: { text: "stableVersion: 1.5.0\n" } } } });
    }
    if (/r0: repository/.test(query)) {
      log.tagReleases++;
      return ok({ data: { r0: { prefixed: null, bare: null } } });
    }
    throw new Error(`unexpected request: ${query.slice(0, 60)}`);
  };
  return { fetchImpl, log };
}

test("a merged PR resolves to its release and to the environments carrying it", async () => {
  const gh = fakeGitHub();
  const [s] = await fetchShipments({ token: "t", fetchImpl: gh.fetchImpl, now: NOW, deployments: newDeploymentsState() });
  assert.deepEqual(s.status, { kind: "released", version: "v1.5.0", url: "https://github.com/acme/w/releases/tag/v1.5.0" });
  assert.deepEqual(s.environments, [{ environment: "staging", status: { kind: "carrying", version: "1.5.0" }, regionsAgree: true }]);
});

test("discovery happens once per repository; later polls read only the tree", async () => {
  const gh = fakeGitHub();
  const deployments = newDeploymentsState();
  await fetchShipments({ token: "t", fetchImpl: gh.fetchImpl, now: NOW, deployments });
  await fetchShipments({ token: "t", fetchImpl: gh.fetchImpl, now: NOW, deployments });
  assert.equal(gh.log.rest, 1); // a rate-limited code search, not repeated
  assert.equal(gh.log.circleci, 1);
  assert.equal(gh.log.trees, 2);
  assert.equal(gh.log.blobs, 1); // unchanged oid: never re-read
  assert.deepEqual(deployments.locations["acme/w"], [{ deploymentsRepo: "acme/deploy", appPath: "chat" }]);
});

test("an unreachable deployments repo costs the chips, not the row", async () => {
  const gh = fakeGitHub({ failDeployments: true });
  const [s] = await fetchShipments({ token: "t", fetchImpl: gh.fetchImpl, now: NOW, deployments: newDeploymentsState() });
  assert.equal(s.status.kind, "released");
  assert.deepEqual(s.environments, []);
});

test("a failed poll leaves the last good promotions in place, so chips do not blank", async () => {
  const deployments = newDeploymentsState();
  await fetchShipments({ token: "t", fetchImpl: fakeGitHub().fetchImpl, now: NOW, deployments });
  const [s] = await fetchShipments({ token: "t", fetchImpl: fakeGitHub({ failDeployments: true }).fetchImpl, now: NOW, deployments });
  assert.equal(s.environments[0].status.kind, "carrying");
});
