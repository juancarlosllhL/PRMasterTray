import { test } from "node:test";
import assert from "node:assert/strict";
import { renderEmoji, stripEmoji, EMOJI } from "../src/core/emoji.js";

test("known shortcodes become their glyph; the rest of the title is untouched", () => {
  assert.equal(renderEmoji(":sparkles: add thing"), "✨ add thing");
  assert.equal(renderEmoji("fix :bug: in :lock: flow"), "fix 🐛 in 🔒️ flow");
  assert.equal(renderEmoji(":+1: and :-1:"), "👍 and 👎");
});

test("a code outside the table is left exactly as written, not stripped or guessed", () => {
  assert.equal(renderEmoji(":foo: bar"), ":foo: bar");
});

test("colons in ordinary text never reach across the title looking for a partner", () => {
  assert.equal(renderEmoji("fix: handle 12:30:45 and :: and a lone : here"), "fix: handle 12:30:45 and :: and a lone : here");
  assert.equal(renderEmoji("note: sparkles: not a code"), "note: sparkles: not a code"); // a space inside the pair
  assert.equal(renderEmoji("time 12:sparkles:30"), "time 12✨30"); // but a real code between digits is still found
});

test("a title with no colon comes back unchanged", () => {
  assert.equal(renderEmoji("plain title"), "plain title");
  assert.equal(renderEmoji(""), "");
});

test("the table covers the gitmoji set and the few GitHub codes common in titles", () => {
  for (const code of ["art", "zap", "fire", "bug", "rocket", "tada", "bookmark", "recycle", "wrench", "package", "warning", "eyes", "x"]) {
    assert.ok(EMOJI[code], code);
  }
  assert.equal(Object.keys(EMOJI).length, 79); // the same table the macOS app ships
});

test("stripping removes both forms: the shortcode and a glyph typed straight into the title", () => {
  assert.equal(stripEmoji(":sparkles: add thing"), "add thing");
  assert.equal(stripEmoji("🐛 fix the crash"), "fix the crash");
  assert.equal(stripEmoji("feat(api): :rocket: ship it 🚀"), "feat(api): ship it");
  assert.equal(stripEmoji("⚠️ careful"), "careful"); // a text-style symbol made an emoji by its variation selector
});

test("stripping leaves words, digits and unknown codes alone, and collapses the gap", () => {
  assert.equal(stripEmoji("fix   :foo:  bar 123"), "fix :foo: bar 123");
  assert.equal(stripEmoji("café résumé"), "café résumé");
});
