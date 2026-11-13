import { test } from "node:test";
import assert from "node:assert/strict";
import { rows, shipmentRows } from "../src/core/rows.js";

const pr = (over) => ({ id: "PR_1", createdAt: "2026-10-29T00:00:00Z", number: 1, title: "T", repo: "acme/w", url: "https://github.com/acme/w/pull/1", readiness: "blocked", ...over });

test("ready pull requests come first, then the rest in the given order", () => {
  const at = (n) => `https://github.com/acme/w/pull/${n}`;
  const entries = rows([
    pr({ url: at(1), readiness: "blocked" }),
    pr({ url: at(2), readiness: "ready" }),
    pr({ url: at(3), readiness: "draft" }),
  ]);
  assert.deepEqual(entries.map((r) => r.url), [at(2), at(1), at(3)]);
});

test("each row carries what the window shows and what its actions need", () => {
  const [r] = rows([pr({ id: "PR_7", number: 7, title: "Fix it", readiness: "checksFailing" })], now);
  assert.equal(r.id, "PR_7");
  assert.equal(r.status, "Checks failing");
  assert.equal(r.number, 7);
});

const now = new Date("2026-10-30T00:00:00Z");

test("a row is stale past the threshold and says how old it is", () => {
  const old = rows([pr({ createdAt: "2026-08-01T00:00:00Z" })], now)[0];
  assert.equal(old.stale, true);
  assert.equal(old.age, "3 months");
  assert.equal(rows([pr({ createdAt: "2026-10-20T00:00:00Z" })], now)[0].stale, false);
});

test("only github.com links are openable", () => {
  assert.deepEqual(rows([pr({ url: "file:///etc/passwd" })]), []);
});

test("empty input gives no entries", () => {
  assert.deepEqual(rows([]), []);
});

const ship = (status, over = {}) => ({ pr: { id: "PR_9", number: 9, title: "Shipped", repo: "acme/w", url: "https://github.com/acme/w/pull/9", ...over }, status });

test("shipment rows say what became of the merge and open where it is worth looking", () => {
  const view = shipmentRows([
    ship({ kind: "pending" }),
    ship({ kind: "building", url: "https://circleci.com/workflow/1" }),
    ship({ kind: "failed", name: "ci/build", url: "https://circleci.com/workflow/2" }),
    ship({ kind: "released", version: "v1.2.0", url: "https://github.com/acme/w/releases/tag/v1.2.0" }),
  ]);
  assert.deepEqual(view.map((v) => v.label), ["Merged", "Building…", "Failed: ci/build", "Released v1.2.0"]);
  assert.deepEqual(view.map((v) => v.kind), ["pending", "building", "failed", "released"]);
  assert.equal(view[0].url, "https://github.com/acme/w/pull/9"); // pending falls back to the PR
  assert.equal(view[3].url, "https://github.com/acme/w/releases/tag/v1.2.0");
});

test("shipment rows only open https links", () => {
  assert.deepEqual(shipmentRows([ship({ kind: "building", url: "file:///etc/passwd" })]), []);
});

const withEnvs = (environments) => ({ ...ship({ kind: "released", version: "v1", url: "https://github.com/acme/w/releases/tag/v1" }), environments });
const env = (environment, kind, version, regionsAgree = true) => ({ environment, status: version === undefined ? { kind } : { kind, version }, regionsAgree });

test("chips: stg/prod, carrying or awaiting; unknown says nothing", () => {
  const [row] = shipmentRows([withEnvs([env("staging", "carrying", "1.5.0"), env("production", "awaiting", "1.4.0")])]);
  assert.deepEqual(row.chips, [
    { label: "stg 1.5.0", kind: "carrying" },
    { label: "prod 1.4.0", kind: "awaiting" },
  ]);
  // No chip means nothing could be established, which is never the same as nothing being there.
  assert.deepEqual(shipmentRows([withEnvs([env("staging", "unknown")])])[0].chips, []);
});

test("regions that disagree show the lowest version as a floor", () => {
  const [row] = shipmentRows([withEnvs([env("production", "carrying", "1.4.0", false)])]);
  assert.equal(row.chips[0].label, "prod ≥1.4.0");
});

test("a shipment with no environments has no chips", () => {
  assert.deepEqual(shipmentRows([ship({ kind: "pending" })])[0].chips, []);
});

test("the stale threshold is a setting: a shorter one flags more, off flags nothing", () => {
  const fortnight = { createdAt: "2026-10-10T00:00:00Z" }; // 20 days before `now`
  assert.equal(rows([pr(fortnight)], now, 14)[0].stale, true);
  assert.equal(rows([pr(fortnight)], now, 30)[0].stale, false);
  assert.equal(rows([pr({ createdAt: "2025-01-01T00:00:00Z" })], now, null)[0].stale, false);
});

test("a shipment row keeps the pull request's own link beside where a click goes, for Copy Link", () => {
  const [row] = shipmentRows([ship({ kind: "building", url: "https://circleci.com/workflow/1" })]);
  assert.equal(row.url, "https://circleci.com/workflow/1");
  assert.equal(row.prURL, "https://github.com/acme/w/pull/9");
});
