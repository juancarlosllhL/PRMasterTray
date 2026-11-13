// Jira issues and GitHub Project items on one board of shared columns. Each source
// keeps its own state, fetch and moves; this only composes them. Port of the
// composition half of BoardStore.swift.
import { BOARD_LANES, group, issueKeyLeading, jiraWindowIncludes, laneOf, matchesSearch, searchTerms } from "./jira.js";

// ---- Card ids ---------------------------------------------------------------
// The drag payload as well: strings dropped from other apps parse to null.

export function cardIdToString(id) {
  if (id.kind === "jira") return `jira:${id.key}`;
  if (id.kind === "project") return `project:${id.item}`;
  return `paired:${id.key}/${id.item}`;
}

export function cardIdFrom(raw) {
  const at = raw.indexOf(":");
  if (at < 0) return null;
  const kind = raw.slice(0, at);
  const rest = raw.slice(at + 1);
  if (!rest) return null;
  if (kind === "jira") return { kind, key: rest };
  if (kind === "project") return { kind, item: rest };
  if (kind === "paired") {
    const slash = rest.indexOf("/");
    if (slash <= 0 || slash === rest.length - 1) return null;
    return { kind, key: rest.slice(0, slash), item: rest.slice(slash + 1) };
  }
  return null;
}

// ---- Cards ------------------------------------------------------------------

const CATEGORY_TINT = { new: "gray", indeterminate: "blue", done: "green" };
// For GitHub cards, which have no status category of their own.
const LANE_TINT = { toDo: "gray", inProgress: "blue", reviewing: "blue", testing: "blue", done: "green" };
const NO_PRIORITY = { name: "None", order: 10_000 };

const time = (iso) => (iso ? new Date(iso).getTime() : -Infinity);

// Priority, then the newest first, then the reference so an exact tie cannot reshuffle on every poll.
function precedes(a, b) {
  if (a.priority.order !== b.priority.order) return a.priority.order - b.priority.order;
  if (time(a.createdAt) !== time(b.createdAt)) return time(b.createdAt) - time(a.createdAt);
  return a.reference < b.reference ? -1 : a.reference > b.reference ? 1 : 0;
}

function finishedFirst(a, b) {
  if (time(a.finishedAt) !== time(b.finishedAt)) return time(b.finishedAt) - time(a.finishedAt);
  return a.reference < b.reference ? -1 : a.reference > b.reference ? 1 : 0;
}

// Item id -> the Jira issue it was copied from, first copy per key. Pull requests
// are left out: `[ACME-123]` on a pull request names the work, not a copy of it.
function migratedCopies(issues, items) {
  const remaining = new Map();
  for (const issue of issues) if (!remaining.has(issue.key)) remaining.set(issue.key, issue);
  const copies = new Map();
  for (const item of items) {
    if (item.isPullRequest) continue;
    const key = issueKeyLeading(item.title)?.key;
    const issue = key && remaining.get(key);
    if (!issue) continue;
    remaining.delete(key);
    copies.set(item.id, issue);
  }
  return copies;
}

// GitHub places and opens the card. Jira's priority, type and age stand, since the
// copy's were set on migration day.
function paired(card, item, issue, { jiraLinks, jiraLinkState, jiraLaneOf }) {
  const fromJira = jiraLinks[issue.key] ?? [];
  const links = [...fromJira, ...card.links.filter((p) => !fromJira.some((j) => j.url === p.url))];
  const sameLane = jiraLaneOf(issue) === card.lane;
  return {
    ...card,
    id: { kind: "paired", key: issue.key, item: item.id },
    sources: [{ kind: "jira" }, ...card.sources],
    reference: issue.key,
    pairedReference: card.reference,
    title: issueKeyLeading(item.title)?.title ?? item.title,
    statusName: sameLane ? card.statusName : `${card.statusName} · Jira: ${issue.statusName}`,
    typeName: issue.issueType,
    priority: issue.priority,
    createdAt: issue.createdAt,
    links,
    linkState: links.length === 0 ? jiraLinkState(issue.key) : "linked",
  };
}

// The board as cards by lane. `issues` are the Jira issues to list (epics already
// left out); `jiraMoves` and `itemMoves` place a card being moved in its target
// lane before the source confirms. `windowDays` is the Done window (null = off).
export function composeBoard({ issues, jiraMoves, jiraLinks, jiraLinkState, items, projects, projectLane, itemMoves, windowDays, now }) {
  const copies = migratedCopies(issues, items);
  const pairedKeys = new Set([...copies.values()].map((i) => i.key));
  const jiraLaneOf = (issue) => jiraMoves[issue.key] ?? laneOf(issue);
  const lanes = Object.fromEntries(BOARD_LANES.map((l) => [l.id, []]));

  const groups = group(issues.filter((i) => !pairedKeys.has(i.key)), { days: windowDays, now, overrides: jiraMoves });
  for (const lane of BOARD_LANES.map((l) => l.id)) {
    for (const issue of groups[lane]) {
      lanes[lane].push({
        id: { kind: "jira", key: issue.key },
        sources: [{ kind: "jira" }],
        reference: issue.key,
        pairedReference: null,
        copyID: issue.key,
        title: issue.summary,
        statusName: issue.statusName,
        typeName: issue.issueType,
        priority: issue.priority,
        tint: CATEGORY_TINT[issue.statusCategory] ?? "gray",
        lane,
        createdAt: issue.createdAt,
        finishedAt: issue.categoryChangedAt,
        url: null, // Jira's link needs the signed-in site
        links: jiraLinks[issue.key] ?? [],
        linkState: jiraLinkState(issue.key),
      });
    }
  }

  for (const item of items) {
    const lane = itemMoves[item.id] ?? projectLane(item);
    if (!lane) continue;
    // Done is held to the window by when the Status was set; a card being moved counts as finishing now.
    const moving = item.id in itemMoves;
    const finishedAt = moving ? now.toISOString() : item.statusChangedAt;
    if (lane === "done" && !jiraWindowIncludes(windowDays, finishedAt, now)) continue;
    const project = projects.find((p) => p.id === item.projectID);
    const card = {
      id: { kind: "project", item: item.id },
      sources: [{ kind: "github", project: project?.title ?? "" }],
      reference: item.reference,
      pairedReference: null,
      copyID: `${item.repo}#${item.number}`,
      title: item.title,
      statusName: project?.options.find((o) => o.id === item.statusOptionID)?.name ?? item.statusName ?? "No Status",
      typeName: item.typeName,
      priority: NO_PRIORITY,
      tint: LANE_TINT[lane],
      lane,
      createdAt: item.createdAt,
      finishedAt,
      url: item.url,
      links: item.links,
      linkState: item.isPullRequest ? null : item.links.length === 0 ? "none" : "linked",
    };
    const copy = copies.get(item.id);
    lanes[lane].push(copy ? paired(card, item, copy, { jiraLinks, jiraLinkState, jiraLaneOf }) : card);
  }

  for (const [lane, cards] of Object.entries(lanes)) cards.sort(lane === "done" ? finishedFirst : precedes);
  return lanes;
}

// What the board draws: the five columns in the order work moves. An empty column
// stays, because it is what says the group exists and has nothing in it; Done is
// the exception, which with its window off can never fill.
export function columnsOf(lanes, { windowDays, query }) {
  const terms = searchTerms(query);
  return BOARD_LANES.filter((l) => l.id !== "done" || windowDays != null).map((l) => ({
    lane: l.id,
    id: l.title,
    title: l.title,
    showsPriority: l.id !== "done",
    cards: lanes[l.id].filter((c) => matchesSearch(`${c.reference} ${c.pairedReference ?? ""} ${c.title}`, terms)),
  }));
}
