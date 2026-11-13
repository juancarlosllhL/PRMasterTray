import { test } from "node:test";
import assert from "node:assert/strict";
import { decideBranchUpdates } from "../src/core/branchUpdate.js";
import { ageLabel, isStale } from "../src/core/staleness.js";

const pr = (id, readiness, headRefOid = "h1") => ({ id, readiness, headRefOid });

test("only behind pull requests are updated, once per head commit", () => {
  const first = decideBranchUpdates([pr("a", "behind"), pr("b", "ready")], new Set());
  assert.deepEqual(first.update.map((p) => p.id), ["a"]);

  // A refused update leaves the head where it was: the key stays, so no retry loop.
  const again = decideBranchUpdates([pr("a", "behind")], first.attempted);
  assert.equal(again.update.length, 0);
});

test("a moved head or a PR that stopped being behind is re-armed", () => {
  const first = decideBranchUpdates([pr("a", "behind", "h1")], new Set());
  assert.equal(decideBranchUpdates([pr("a", "behind", "h2")], first.attempted).update.length, 1);
  const away = decideBranchUpdates([pr("a", "ready", "h1")], first.attempted);
  assert.equal(away.attempted.size, 0);
});

const DAY = 86_400_000;
const now = new Date("2026-10-30T00:00:00Z");
const ago = (days) => new Date(now - days * DAY).toISOString();

test("stale means strictly older than the threshold", () => {
  assert.equal(isStale(ago(30), now, 30), false);
  assert.equal(isStale(ago(31), now, 30), true);
  assert.equal(isStale(ago(500), now, null), false); // null threshold = off
});

test("age labels: days, then months, then years", () => {
  assert.equal(ageLabel(ago(1), now), "1 day");
  assert.equal(ageLabel(ago(59), now), "59 days");
  assert.equal(ageLabel(ago(60), now), "2 months");
  assert.equal(ageLabel(ago(365), now), "1 year");
  assert.equal(ageLabel(ago(800), now), "2 years");
  assert.equal(ageLabel(new Date(now.getTime() + DAY).toISOString(), now), "0 days"); // clock ahead of GitHub's
});
