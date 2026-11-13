// What a diff window is sent: everything it draws, in one plain object. Built here
// rather than in the Electron module so it can be tested.
import { sectionHeading } from "./fileScope.js";
import { heatMarks } from "./scoring.js";

// A family name comes from a settings file and ends up in CSS, so anything that
// could close the quote or the declaration is dropped.
const safeFamily = (name) => name.replace(/["';{}\\]/g, "").trim();

export function fontFrom({ diffFontFamily, diffFontSize, diffLigatures }) {
  const chosen = diffFontFamily ? safeFamily(diffFontFamily) : "";
  return {
    family: chosen ? `"${chosen}", Consolas, monospace` : 'Consolas, "Cascadia Mono", monospace',
    size: diffFontSize,
    ligatures: diffLigatures,
  };
}

export function diffPayload({ meta, phase, error, viewedErrors, view, isTruncated, canMerge, canApprove, settings, description, score }) {
  return {
    ...meta,
    phase,
    error,
    viewedErrors,
    isTruncated,
    canMerge,
    canApprove,
    description,
    score,
    heatMarks: view.heatShown ? heatMarks(view.rows) : [],
    layout: view.layout,
    font: fontFrom(settings),
    counts: { viewed: view.viewedReviewCount, review: view.reviewFiles.length, setAside: view.setAsideCount },
    sidebar: view.groups.map((g) => ({
      section: g.section,
      heading: sectionHeading(g.section, g.files.length),
      files: g.files.map((f) => ({
        path: f.path,
        previousPath: f.previousPath,
        change: f.change,
        additions: f.additions,
        deletions: f.deletions,
        viewed: f.viewed === "VIEWED",
        collapsed: view.isCollapsed(f.path),
        heat: view.heatShown ? (view.fileHeat.get(f.path) ?? null) : null,
      })),
    })),
    rows: view.rows,
    find: {
      query: view.findQuery,
      total: view.findMatches.length,
      current: view.currentFindIndex,
      matches: view.findMatches,
    },
  };
}
