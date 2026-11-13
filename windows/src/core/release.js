// Release housekeeping, run by the workflow. Port of `make verify-version` and
// scripts/release-notes.sh.

// The updater compares a release tag against the running app's version, so a tag
// that disagrees with package.json would either offer an update the user already
// has — forever — or never fire at all. Compared as plain strings: a tag name may
// legally contain backticks or `$(…)`, and nothing here may expand it.
export const tagMatchesVersion = (tag, version) => tag === `windows-v${version}`;

// The body of the changelog's section for `version`, without its heading. Empty when
// there is none, so the caller can fall back to generated notes.
export function notesFor(markdown, version) {
  const lines = markdown.split("\n");
  const start = lines.findIndex((l) => l.startsWith("## ") && l.slice(3).trim().split(/\s+/)[0].replace(/^v/, "") === version);
  if (start < 0) return "";
  const end = lines.findIndex((l, i) => i > start && l.startsWith("## "));
  return lines.slice(start + 1, end < 0 ? undefined : end).join("\n").trim();
}
