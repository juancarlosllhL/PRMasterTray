import { test } from "node:test";
import assert from "node:assert/strict";
import { parseHunks } from "../src/core/patch.js";

const patch = (...lines) => lines.join("\n");

test("numbers old and new lines from the hunk header", () => {
  const [h] = parseHunks(patch("@@ -10,3 +20,4 @@", " keep", "-gone", "+new1", "+new2", " tail"));
  assert.deepEqual(h.lines.map((l) => [l.kind, l.oldNumber, l.newNumber, l.text]), [
    ["context", 10, 20, "keep"],
    ["removed", 11, null, "gone"],
    ["added", null, 21, "new1"],
    ["added", null, 22, "new2"],
    ["context", 12, 23, "tail"],
  ]);
  assert.deepEqual([h.oldStart, h.oldCount, h.newStart, h.newCount], [10, 3, 20, 4]);
});

test("an omitted count means one line, and the function context after @@ is kept", () => {
  const [h] = parseHunks(patch("@@ -5 +5 @@ function render() {", "-a", "+b"));
  assert.deepEqual([h.oldCount, h.newCount, h.context], [1, 1, "function render() {"]);
});

test("several hunks, each numbered on its own", () => {
  const hunks = parseHunks(patch("@@ -1,1 +1,1 @@", "-a", "+b", "@@ -50,1 +60,1 @@", "-c", "+d"));
  assert.deepEqual(hunks.map((h) => h.lines[0].oldNumber), [1, 50]);
  assert.deepEqual(hunks.map((h) => h.lines[1].newNumber), [1, 60]);
});

test("CRLF endings are stripped, and a missing final newline marks the line before it", () => {
  const [h] = parseHunks("@@ -1,1 +1,1 @@\r\n-old\r\n+new\r\n\\ No newline at end of file\r\n");
  assert.equal(h.lines[0].text, "old");
  assert.equal(h.lines[1].noNewlineAtEnd, true);
  assert.equal(h.lines[0].noNewlineAtEnd, false);
});

test("a blank context line that lost its leading space is still context", () => {
  const [h] = parseHunks(patch("@@ -1,2 +1,2 @@", "", "-x", "+y"));
  assert.equal(h.lines[0].kind, "context");
  assert.equal(h.lines[0].text, "");
});

test("a line starting with - or + beyond the header's counts is refused, not misnumbered", () => {
  assert.throws(() => parseHunks(patch("@@ -1,1 +1,1 @@", "-a", "+b", "+extra")), /unexpected|header/i);
});

test("a patch that ends before its header's counts are met is refused", () => {
  assert.throws(() => parseHunks(patch("@@ -1,3 +1,3 @@", " a")), /truncated/i);
});

test("a malformed header is refused", () => {
  for (const bad of ["not a hunk", "@@ -x,1 +1,1 @@", "@@ -1,1 @@", "@@ -1,1 +1,1"]) {
    assert.throws(() => parseHunks(bad), /malformed/i, bad);
  }
});

test("no patch text means no hunks", () => {
  assert.deepEqual(parseHunks(""), []);
});

test("a marker with nothing before it is refused", () => {
  assert.throws(() => parseHunks(patch("@@ -0,0 +1,0 @@", "\\ No newline at end of file")), /unexpected/i);
});
