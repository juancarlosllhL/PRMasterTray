// What one diff window shows: files sorted into sections, the open/closed state of
// each, and the table rows for unified or split layout. Port of DiffRows.swift,
// DiffSearch.swift and the view state of DiffStore.swift (network and scoring live
// elsewhere).
import { applyHeat } from "./scoring.js";
import { compileScope, DEFAULT_PATTERNS, SECTION_TITLES, SECTIONS, sectionOf } from "./fileScope.js";

const hunkHeaderText = (h) => {
  const ranges = `@@ -${h.oldStart},${h.oldCount} +${h.newStart},${h.newCount} @@`;
  return h.context ? `${ranges} ${h.context}` : ranges;
};

// Pairs the removed and added lines of each change block in order, as GitHub
// does. Context ends a block and sits on both sides.
export function splitHunk(hunk) {
  const rows = [{ type: "hunkHeader", text: hunkHeaderText(hunk) }];
  let removed = [];
  let added = [];
  const flush = () => {
    for (let i = 0; i < Math.max(removed.length, added.length); i++) {
      rows.push({ type: "pair", left: removed[i] ?? null, right: added[i] ?? null });
    }
    removed = [];
    added = [];
  };
  for (const line of hunk.lines) {
    if (line.kind === "context") {
      flush();
      rows.push({ type: "pair", left: line, right: line });
    } else if (line.kind === "removed") {
      if (added.length > 0) flush(); // a removal after additions starts a new block
      removed.push(line);
    } else {
      added.push(line);
    }
  }
  flush();
  return rows;
}

function fileRows(files, layout, isCollapsed) {
  const rows = [];
  for (const file of files) {
    rows.push({ type: "fileHeader", path: file.path });
    if (isCollapsed(file.path)) continue;
    if (file.content.kind === "omitted") {
      rows.push({ type: "omitted", reason: file.content.reason });
      continue;
    }
    for (const hunk of file.content.hunks) {
      if (layout === "split") rows.push(...splitHunk(hunk));
      else rows.push({ type: "hunkHeader", text: hunkHeaderText(hunk) }, ...hunk.lines.map((line) => ({ type: "line", line })));
    }
  }
  return rows;
}

// Review files first, then each set-aside group that has files, behind a divider.
export function buildRows(groups, layout, isCollapsed) {
  const rows = [];
  for (const section of SECTIONS) {
    const files = groups.filter((g) => g.section === section).flatMap((g) => g.files);
    if (section !== "review" && files.length > 0) rows.push({ type: "section", section, title: SECTION_TITLES[section], count: files.length });
    rows.push(...fileRows(files, layout, isCollapsed));
  }
  return rows;
}

// Case-insensitive and literal. Ranges are [start, end) in UTF-16 units, which is
// what string indexing in the renderer uses.
function rangesOf(query, text) {
  if (!query.trim()) return [];
  const haystack = text.toLowerCase();
  const needle = query.toLowerCase();
  const found = [];
  for (let at = haystack.indexOf(needle); at >= 0; at = haystack.indexOf(needle, at + needle.length)) {
    found.push([at, at + needle.length]);
  }
  return found;
}

export function findMatches(query, rows) {
  if (!query.trim()) return [];
  const found = [];
  rows.forEach((row, index) => {
    const sides = row.type === "line" ? [row.line] : row.type === "pair" ? [row.left, row.right] : [];
    sides.forEach((line, column) => {
      if (!line) return;
      for (const [start, end] of rangesOf(query, line.text)) found.push({ row: index, column, start, end });
    });
  });
  return found;
}

export class DiffView {
  constructor({ layout = "unified", patterns = DEFAULT_PATTERNS } = {}) {
    this.layout = layout;
    this.patterns = patterns;
    this.files = [];
    this.groups = [];
    this.rows = [];
    this.findQuery = "";
    this.findMatches = [];
    this.currentFindIndex = null;
    this.sections = new Map();
    this.collapsedReview = new Set();
    this.expandedSetAside = new Set();
    this.scores = new Map(); // path -> one score per block
    this.fileHeat = new Map(); // path -> { state, level, message }
    this.heatShown = false;
  }

  // Replaces everything: a reload keeps none of the old open/closed choices.
  load(diff) {
    this.files = diff.files;
    this.gitAttributes = diff.gitAttributes ?? null;
    this.scope = compileScope({ patterns: this.patterns, gitAttributes: this.gitAttributes });
    this.collapsedReview = new Set(diff.files.filter((f) => f.viewed === "VIEWED").map((f) => f.path));
    this.expandedSetAside = new Set();
    this.scores = new Map();
    this.fileHeat = new Map();
    this.classify();
    this.rebuild();
  }

  // A settings change: re-sorts the files without forgetting what was opened or closed.
  reclassify({ patterns, gitAttributes } = {}) {
    if (patterns) this.patterns = patterns;
    if (gitAttributes !== undefined) this.gitAttributes = gitAttributes;
    this.scope = compileScope({ patterns: this.patterns, gitAttributes: this.gitAttributes });
    this.classify();
    this.rebuild();
  }

  classify() {
    this.sections = new Map(this.files.map((f) => [f.path, sectionOf(f.path, this.scope)]));
  }

  get reviewFiles() {
    return this.groups.find((g) => g.section === "review")?.files ?? [];
  }

  get viewedReviewCount() {
    return this.reviewFiles.filter((f) => f.viewed === "VIEWED").length;
  }

  get setAsideCount() {
    return this.files.length - this.reviewFiles.length;
  }

  // Review files stay open until viewed; set-aside files stay closed until opened.
  // Both sets are kept whatever the scope, so a scope change undoes cleanly.
  isCollapsed(path) {
    return (this.sections.get(path) ?? "review") === "review" ? this.collapsedReview.has(path) : !this.expandedSetAside.has(path);
  }

  setCollapsed(path, collapsed) {
    if (collapsed) {
      this.collapsedReview.add(path);
      this.expandedSetAside.delete(path);
    } else {
      this.collapsedReview.delete(path);
      this.expandedSetAside.add(path);
    }
  }

  toggleCollapsed(path) {
    this.setCollapsed(path, !this.isCollapsed(path));
    this.rebuild();
  }

  setViewedLocally(path, viewed) {
    const file = this.files.find((f) => f.path === path);
    if (!file) return;
    file.viewed = viewed ? "VIEWED" : "UNVIEWED";
    this.setCollapsed(path, viewed);
    this.rebuild();
  }

  setLayout(layout) {
    if (layout === this.layout) return;
    this.layout = layout;
    this.rebuild();
  }

  setFindQuery(query) {
    this.findQuery = query;
    this.search(false);
  }

  get currentFindMatch() {
    return this.currentFindIndex === null ? null : this.findMatches[this.currentFindIndex];
  }

  findNext() {
    this.moveFind(1);
  }

  findPrevious() {
    this.moveFind(-1);
  }

  moveFind(step) {
    if (this.currentFindIndex === null || this.findMatches.length === 0) return;
    this.currentFindIndex = (this.currentFindIndex + step + this.findMatches.length) % this.findMatches.length;
  }

  search(keepingPlace) {
    this.findMatches = findMatches(this.findQuery, this.rows);
    if (this.findMatches.length === 0) {
      this.currentFindIndex = null;
      return;
    }
    this.currentFindIndex = keepingPlace ? Math.min(this.currentFindIndex ?? 0, this.findMatches.length - 1) : 0;
  }

  // Heat is drawn only once the reviewer asked for it; the scores are kept either way.
  setScores(path, scores) {
    this.scores.set(path, scores);
    this.rebuild();
  }

  setFileHeat(path, state) {
    this.fileHeat.set(path, state);
  }

  setHeatShown(shown) {
    if (shown === this.heatShown) return;
    this.heatShown = shown;
    this.rebuild();
  }

  // The loaded diff is never written into: heat lives on copies of the rows' files.
  scored(file) {
    const scores = this.scores.get(file.path);
    return this.heatShown && scores ? applyHeat(file, scores) : file;
  }

  rebuild() {
    this.groups = SECTIONS.flatMap((section) => {
      const files = this.files.filter((f) => (this.sections.get(f.path) ?? "review") === section);
      return files.length ? [{ section, files: files.map((f) => this.scored(f)) }] : [];
    });
    this.rows = buildRows(this.groups, this.layout, (path) => this.isCollapsed(path));
    this.search(true);
  }
}

