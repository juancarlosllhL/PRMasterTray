import { test } from "node:test";
import assert from "node:assert/strict";
import { BUCKETS, bucketFor, linesFor, quipFor } from "../src/core/approvalQuip.js";

const now = new Date("2026-10-30T10:00:00Z");
const request = (over = {}) => ({ title: "Improve the thing", additions: 60, deletions: 10, changedFiles: 3, checks: "SUCCESS", reviewDecision: null, createdAt: "2026-10-28T10:00:00Z", ...over });

test("the shape of the diff outranks what the title claims, which outranks the state of the row", () => {
  // Order is the precedence: deletion-heavy first.
  assert.equal(bucketFor(request({ deletions: 500, additions: 100, changedFiles: 500, title: "fix" }), now), "deletionHeavy");
  assert.equal(bucketFor(request({ changedFiles: 101 }), now), "countlessFiles");
  assert.equal(bucketFor(request({ additions: 5000, deletions: 1 }), now), "enormous");
  assert.equal(bucketFor(request({ additions: 2001 }), now), "huge");
  assert.equal(bucketFor(request({ additions: 1000 }), now), "big");
  assert.equal(bucketFor(request({ changedFiles: 51 }), now), "veryManyFiles");
  assert.equal(bucketFor(request({ changedFiles: 21 }), now), "manyFiles");
  assert.equal(bucketFor(request({ additions: 20, deletions: 5 }), now), "tiny");
  assert.equal(bucketFor(request({ changedFiles: 1 }), now), "singleFile");
});

test("boundaries are the ones the original draws: 100 deletions and three times the additions; exactly 1000 lines is big", () => {
  assert.equal(bucketFor(request({ deletions: 99, additions: 0 }), now) === "deletionHeavy", false);
  assert.equal(bucketFor(request({ deletions: 100, additions: 33 }), now), "deletionHeavy");
  assert.equal(bucketFor(request({ deletions: 100, additions: 34 }), now) === "deletionHeavy", false);
  assert.equal(bucketFor(request({ additions: 999, deletions: 0 }), now) === "big", false);
  assert.equal(bucketFor(request({ additions: 49, deletions: 0 }), now), "tiny");
  assert.equal(bucketFor(request({ additions: 50, deletions: 0 }), now) === "tiny", false);
});

test("the title is read by whole words, shortcodes included, so `fix` never matches `prefix`", () => {
  assert.equal(bucketFor(request({ title: "fix: handle nulls" }), now), "fixes");
  assert.equal(bucketFor(request({ title: ":bug: handle nulls" }), now), "fixes");
  assert.equal(bucketFor(request({ title: "prefix the keys" }), now), "generic");
  assert.equal(bucketFor(request({ title: "Revert \"add thing\"" }), now), "revert");
  assert.equal(bucketFor(request({ title: "refactor: split module" }), now), "refactor");
  assert.equal(bucketFor(request({ title: ":arrow_up: bump lodash" }), now), "dependencies"); // the underscore stays: arrow_up is one word
  assert.equal(bucketFor(request({ title: "add coverage for parser" }), now), "tests");
  assert.equal(bucketFor(request({ title: "update README" }), now), "documentation");
});

test("when several title words match, the earlier bucket wins: a revert of a fix is a revert", () => {
  assert.equal(bucketFor(request({ title: "revert fix for docs" }), now), "revert");
});

test("then the row's own state: failing or pending checks, a forgotten one, a fresh one, a pile-on", () => {
  assert.equal(bucketFor(request({ checks: "FAILURE" }), now), "checksFailing");
  assert.equal(bucketFor(request({ checks: "ERROR" }), now), "checksFailing");
  assert.equal(bucketFor(request({ checks: "PENDING" }), now), "checksPending");
  assert.equal(bucketFor(request({ checks: "EXPECTED" }), now), "checksPending");
  assert.equal(bucketFor(request({ createdAt: "2026-10-01T00:00:00Z" }), now), "forgotten");
  assert.equal(bucketFor(request({ createdAt: "2026-10-30T09:30:00Z" }), now), "fresh");
  assert.equal(bucketFor(request({ reviewDecision: "APPROVED" }), now), "piledOn");
  assert.equal(bucketFor(request({ checks: null }), now), "generic"); // no CI at all is not a failure
});

test("every bucket has lines to choose from, and each is a remark that opens by approving", () => {
  assert.ok(BUCKETS.length >= 20);
  for (const bucket of BUCKETS) {
    const lines = linesFor(bucket);
    assert.ok(lines.length >= 4, bucket);
    for (const line of lines) assert.match(line, /^(Approved|Sorry for the wait — approved|That was quick|Opened and approved|LGTM|Ship it)/, `${bucket}: ${line}`);
  }
});

test("the pick is injected so the choice can be pinned, and is clamped rather than trusted", () => {
  const r = request({ changedFiles: 1 });
  const lines = linesFor("singleFile");
  assert.equal(quipFor(r, now, () => 0), lines[0]);
  assert.equal(quipFor(r, now, () => 2), lines[2]);
  assert.equal(quipFor(r, now, () => 999), lines.at(-1)); // a joke has no business failing an approval
  assert.equal(quipFor(r, now, () => -5), lines[0]);
  assert.equal(quipFor(r, now, () => NaN), lines[0]);
});

test("by default the line is random but always one of the bucket's", () => {
  const r = request({ changedFiles: 1 });
  for (let i = 0; i < 20; i++) assert.ok(linesFor("singleFile").includes(quipFor(r, now)));
});
