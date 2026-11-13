// The pure side of the Board: Jira keys, priorities, columns and grouping. Port of
// JiraIssueKey.swift, JiraPriority.swift, JiraGrouping.swift, JiraWindow.swift,
// JiraIssueType.swift, JiraSearch.swift and BoardLane.swift.

// ---- Keys -------------------------------------------------------------------

// Lansweeper's Jira projects, plus POC. A known list rather than any `ABC-123`,
// because titles also carry UTF-8 and RFC-002.
const PROJECTS = new Set([
  "AAFSP", "ACME", "CDKC", "CHSP", "DATA", "ENSE", "EPI", "ETEO", "FING",
  "GROW", "INDIRECT", "ITD", "ITP", "LAN", "LS", "OI", "OPSLI", "PI",
  "PLAT", "POC", "PRODUCT", "REL", "SC", "SKILLS", "TS", "UXT",
]);

export function issueKeyFirst(title) {
  for (const m of title.matchAll(/\b([A-Z][A-Z0-9]*)-([1-9][0-9]*)\b/g)) {
    if (PROJECTS.has(m[1])) return m[0];
  }
  return null;
}

// A GitHub issue migrated from Jira keeps its key as a `[ACME-123]` prefix.
export function issueKeyLeading(title) {
  const m = title.match(/^\s*\[([A-Z][A-Z0-9]*)-([1-9][0-9]*)\]\s*/);
  if (!m || !PROJECTS.has(m[1])) return null;
  return { key: `${m[1]}-${m[2]}`, title: title.slice(m[0].length) };
}

// ---- Priority ---------------------------------------------------------------

// Ordered by Jira's own numeric priority id. `unset` is 10000 rather than 6,
// which keeps it sorting last.
const PRIORITIES = [
  { name: "Critical", order: 1 }, { name: "High", order: 2 }, { name: "Medium", order: 3 },
  { name: "Low", order: 4 }, { name: "Lowest", order: 5 },
];
const UNSET = { name: "None", order: 10_000 };

// An id this site does not define resolves to unset, never critical, so an
// unrecognised value cannot float to the top of the list.
export const priorityFromId = (id) => PRIORITIES.find((p) => String(p.order) === String(id)) ?? UNSET;
export const priorityOrder = (name) => (PRIORITIES.find((p) => p.name === name) ?? UNSET).order;

// ---- Columns ----------------------------------------------------------------

// A board column, and the target of a move. Ordered the way work moves, so how
// far a status is from a target is a difference of positions.
export const BOARD_LANES = [
  { id: "toDo", title: "To do" },
  { id: "inProgress", title: "In progress" },
  { id: "reviewing", title: "Reviewing" },
  { id: "testing", title: "Testing" },
  { id: "done", title: "Done" },
];
export const laneIndex = (id) => BOARD_LANES.findIndex((l) => l.id === id);

// The To do category also holds parked work (On Hold, Awaiting Customer,
// Canceled), which is not waiting to be picked up.
const STARTABLE = new Set(["new", "to do", "todo"]);

// Whole words, or "Latest" and "Contested" would read as work in test.
const hasWord = (statusName, words) => statusName.toLowerCase().split(/[^\p{L}]+/u).some((w) => words.has(w));
const isTesting = (name) => hasWord(name, new Set(["testing", "test"]));
const isReviewing = (name) => hasWord(name, new Set(["reviewing", "review"]));

// Jira names statuses in each user's profile language, but the ids are the site's own.
const LANE_BY_STATUS_ID = { 10000: "toDo", 10029: "toDo", 3: "inProgress", 1: "reviewing", 6: "testing", 10001: "done" };

// The one place a status is given a column, so grouping and choosing where a move
// lands cannot disagree. null is parked work, shown nowhere. Categories are Jira's
// category *keys*: the site returns key `new` under the name "To Do", so matching
// on the display name would break wherever a category is renamed or localised.
export function laneOfStatus({ statusName, statusCategory, statusID }) {
  if (statusID != null && LANE_BY_STATUS_ID[statusID]) return LANE_BY_STATUS_ID[statusID];
  switch (statusCategory) {
    case "new":
      return STARTABLE.has(statusName.trim().toLowerCase()) ? "toDo" : null;
    case "done":
      return "done";
    default: // indeterminate, and an unknown category: still work in flight, and dropping it would hide the issue outright
      if (isTesting(statusName)) return "testing";
      return isReviewing(statusName) ? "reviewing" : "inProgress";
  }
}

export const laneOf = (issue) => laneOfStatus(issue);
export const laneForStatusId = (id) => LANE_BY_STATUS_ID[id] ?? null;

// ---- The Done window --------------------------------------------------------

const DAY_MS = 86_400_000;

// `statusCategoryChangedDate`, not `resolutiondate`: an issue can reach Done
// carrying no resolution date, and one such issue was measured inside the 30 day
// window on the account this was built for.
export const jiraWindowQualifier = (days) => (days == null ? null : `statusCategoryChangedDate >= -${days}d`);

export function jiraWindowIncludes(days, finishedAt, now) {
  if (days == null || !finishedAt) return false;
  return now - new Date(finishedAt) < days * DAY_MS;
}

// ---- Grouping ---------------------------------------------------------------

// Priority, then the newest first, then the key so an exact tie cannot reshuffle
// the list on every poll.
function precedes(a, b) {
  if (a.priority.order !== b.priority.order) return a.priority.order - b.priority.order;
  const created = (i) => (i.createdAt ? new Date(i.createdAt).getTime() : -Infinity);
  if (created(a) !== created(b)) return created(b) - created(a);
  return a.key < b.key ? -1 : a.key > b.key ? 1 : 0;
}

// Filtered against the window here as well as in the query, because a poll can be
// minutes old. `overrides` places a card being moved in its target lane before
// Jira confirms; a card moved to Done counts as finishing now.
export function group(issues, { days, now, overrides = {} }) {
  const lanes = { toDo: [], inProgress: [], reviewing: [], testing: [], done: [] };
  for (const issue of issues) {
    const moving = overrides[issue.key];
    const lane = moving ?? laneOf(issue);
    if (!lane) continue;
    if (lane === "done" && !jiraWindowIncludes(days, moving ? now : issue.categoryChangedAt, now)) continue;
    lanes[lane].push(issue);
  }
  const doneAt = (i) => (i.categoryChangedAt ? new Date(i.categoryChangedAt).getTime() : -Infinity);
  const out = {
    toDo: lanes.toDo.sort(precedes),
    inProgress: lanes.inProgress.sort(precedes),
    reviewing: lanes.reviewing.sort(precedes),
    testing: lanes.testing.sort(precedes),
    done: lanes.done.sort((a, b) => doneAt(b) - doneAt(a)),
  };
  const count = Object.values(out).reduce((n, list) => n + list.length, 0);
  return { ...out, count, isEmpty: count === 0 };
}

// ---- Types and search -------------------------------------------------------

// Matched on a substring because sites rename their types freely, and support is
// checked first so "Customer Support Ticket" is not read as something else.
export function issueTypeTint(name) {
  const folded = name.trim().toLowerCase();
  if (folded.includes("support")) return "yellow";
  if (folded.includes("bug")) return "red";
  if (folded.includes("story")) return "green";
  if (folded.includes("task")) return "blue";
  return "gray";
}

// Only support is shortened: it is the one name long enough to push the status
// and the pull request count off the end of a row.
export function issueTypeShortName(name) {
  const trimmed = name.trim();
  return trimmed.toLowerCase().includes("support") ? "CST" : trimmed;
}

const fold = (text) => text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

// Words rather than a phrase, so "extract logic" finds a card whose title separates the two.
export const searchTerms = (query) => fold(query).split(/\s+/).filter(Boolean);
export const matchesSearch = (text, terms) => terms.length === 0 || terms.every((t) => fold(text).includes(t));

// ---- GitHub Status options --------------------------------------------------

// A GitHub Status option is only a name. Backlog and refinement are not yet work,
// so they start hidden (null). One that names nothing known lands in progress, as
// Jira's unknown category does: visible and fixable beats hidden.
export function guessLane(optionName) {
  const words = new Set(optionName.toLowerCase().split(/[^\p{L}]+/u).filter(Boolean));
  const any = (list) => list.some((w) => words.has(w));
  if (any(["blocked", "hold", "cancelled", "canceled", "won", "parked", "backlog", "refinement"])) return null;
  if (any(["done", "closed", "released", "shipped", "complete", "completed"])) return "done";
  if (any(["qa", "test", "testing"])) return "testing";
  if (any(["review", "reviewing"])) return "reviewing";
  if (any(["todo", "ready", "new", "draft"]) || (words.size === 2 && words.has("to") && words.has("do"))) return "toDo";
  return "inProgress";
}
