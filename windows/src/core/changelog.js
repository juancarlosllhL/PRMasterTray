// Reads the bundled changelog and decides what a launch has to show. Port of
// Changelog.swift: deliberately not a Markdown parser — the file is written to
// this shape and anything it does not recognise is left out rather than guessed at.
import { isNewer, stripVersion } from "./promotion.js";

// A bare file name only. Anything with a path separator is refused rather than
// resolved, so a changelog cannot point the window at a file on disk.
function imageIn(line) {
  const open = line.indexOf("(");
  const close = line.lastIndexOf(")");
  if (open < 0 || close < open) return null;
  const name = line.slice(open + 1, close).trim();
  return !name || /[/\\]/.test(name) || name === "." || name === ".." ? null : name;
}

export function parseChangelog(markdown) {
  const entries = [];
  let version = null;
  let lines = [];
  let image = null;
  const close = () => {
    if (version) entries.push({ version, lines, image });
    lines = [];
    image = null;
  };
  for (const raw of markdown.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("## ")) {
      close();
      const first = line.slice(3).trim().split(/\s+/)[0];
      version = first ? stripVersion(first) : null;
    } else if (line.startsWith("- ") && version) {
      lines.push(line.slice(2));
    } else if (line.startsWith("![") && version && image === null) {
      image = imageIn(line);
    }
  }
  close();
  return entries;
}

// Which entries a launch has to show, if any. Nothing on a fresh install, when the
// running version was already seen, or when the changelog says nothing about it.
export function whatsNewEntries({ entries, current, lastSeen, isFirstRun }) {
  if (isFirstRun || lastSeen === current) return [];
  if (!entries.some((e) => e.version === current)) return [];
  // Nothing recorded means an upgrade from before this existed, which can only
  // speak for the release that introduced it.
  if (!lastSeen) return entries.filter((e) => e.version === current);
  return entries.filter((e) => isNewer(e.version, lastSeen) && !isNewer(e.version, current));
}
