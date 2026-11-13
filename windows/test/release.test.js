import { test } from "node:test";
import assert from "node:assert/strict";
import { notesFor, tagMatchesVersion } from "../src/core/release.js";

test("a release tag must be windows-v<version>: a mismatch would re-offer an update forever, or never offer one", () => {
  assert.equal(tagMatchesVersion("windows-v0.1.0", "0.1.0"), true);
  assert.equal(tagMatchesVersion("windows-v0.1.1", "0.1.0"), false);
  assert.equal(tagMatchesVersion("v0.1.0", "0.1.0"), false); // the macOS tag scheme
  assert.equal(tagMatchesVersion("windows-v0.1.0-rc1", "0.1.0"), false);
  assert.equal(tagMatchesVersion("", "0.1.0"), false);
});

test("a tag is data: nothing in it is ever expanded or evaluated", () => {
  assert.equal(tagMatchesVersion("windows-v0.1.0`id`", "0.1.0"), false);
  assert.equal(tagMatchesVersion("windows-v$(id)", "0.1.0"), false);
});

const MD = "# Changelog\n\nintro\n\n## 0.2.0 — 2026-10-30\n\n- Two\n- Deux\n\n## 0.1.0 — 2026-10-01\n\n- One\n";

test("the notes are the changelog's own section for that version, without its heading", () => {
  assert.equal(notesFor(MD, "0.2.0"), "- Two\n- Deux");
  assert.equal(notesFor(MD, "0.1.0"), "- One");
});

test("a version with no section gives nothing, so the workflow can fall back to generated notes", () => {
  assert.equal(notesFor(MD, "9.9.9"), "");
  assert.equal(notesFor("", "0.1.0"), "");
});
