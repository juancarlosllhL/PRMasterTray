// What the Board tab draws, from the two sources' state. The pane/failure half of
// BoardStore.swift and PaneState.swift.
import { cardIdToString, columnsOf, composeBoard } from "./board.js";

// What a pane draws instead of, or alongside, its rows. Branch order is
// load-bearing: rows first, so a failed refresh never blanks a list already on
// screen; then the error, so a first-fetch failure cannot sit on "Loading…".
export function resolvePane({ rowCount, hiddenCount, lastError, lastSuccessfulFetch }) {
  if (rowCount > 0) return lastError ? "stale" : "content";
  if (lastError) return "failed";
  if (!lastSuccessfulFetch) return "loading";
  return hiddenCount > 0 ? "emptyByFilter" : "empty";
}

const lanesOf = (moves) => Object.fromEntries(Object.entries(moves).map(([id, m]) => [id, m.lane]));

export function boardView({ jira, projects, windowDays, query, siteURL, now, filter = null }) {
  const lanes = composeBoard({
    issues: jira.issues,
    jiraMoves: lanesOf(jira.moves),
    jiraLinks: jira.links,
    jiraLinkState: (key) => jira.linkState(key),
    items: projects.items,
    projects: projects.projects,
    projectLane: (item) => projects.laneOf(item),
    itemMoves: lanesOf(projects.moves),
    windowDays,
    now,
  });

  const isMoving = (id) => (id.kind === "jira" ? jira.isMoving(id.key) : id.kind === "project" ? projects.isMoving(id.item) : jira.isMoving(id.key) || projects.isMoving(id.item));
  const canMove = (id) => (id.kind === "jira" ? jira.canMove : projects.canMove);
  const decorate = (card) => ({
    ...card,
    idString: cardIdToString(card.id),
    links: filter ? card.links.filter((l) => filter.includes(l)) : card.links,
    moving: isMoving(card.id),
    canMove: canMove(card.id),
    // Jira's link needs the signed-in site.
    openURL: card.url ?? (card.id.kind === "jira" && siteURL ? `${siteURL}/browse/${card.id.key}` : null),
  });

  const columns = columnsOf(lanes, { windowDays, query }).map((c) => ({ ...c, cards: c.cards.map(decorate) }));
  const visibleCount = columns.reduce((n, c) => n + c.cards.length, 0);
  const cardCount = Object.values(lanes).reduce((n, cards) => n + cards.length, 0); // whatever the search, for the tab's badge

  const sources = [];
  if (jira.isConfigured) sources.push({ name: "Jira", lastError: jira.lastError, lastSuccessfulFetch: jira.lastSuccessfulFetch });
  if (projects.isConfigured) sources.push({ name: "GitHub Projects", lastError: projects.lastError, lastSuccessfulFetch: projects.lastSuccessfulFetch });

  // Failed when every source that is set up failed, or when nothing at all is on
  // the board and one of them failed: an empty Jira says nothing about a GitHub
  // board that never answered. Loading until each source has answered.
  const failed = sources.filter((s) => s.lastError);
  const allFailed = sources.length > 0 && failed.length === sources.length;
  const waiting = sources.some((s) => !s.lastSuccessfulFetch && !s.lastError);
  const successes = sources.map((s) => s.lastSuccessfulFetch).filter(Boolean);
  const paneState = resolvePane({
    rowCount: visibleCount,
    hiddenCount: jira.issues.length + projects.items.length - visibleCount,
    lastError: allFailed || cardCount === 0 ? (failed[0]?.lastError ?? null) : null,
    lastSuccessfulFetch: waiting || successes.length === 0 ? null : new Date(Math.max(...successes.map((d) => +d))),
  });

  // One line per source that failed, so an actionable reason such as the missing
  // project scope is never hidden behind another source's.
  const failureLines = failed.map((s) => `Couldn't reach ${s.name} — ${s.lastError.message}`);
  const request = jira.fieldRequest;

  return {
    isConfigured: jira.isConfigured || projects.isConfigured,
    paneState,
    columns,
    visibleCount,
    cardCount,
    failureLines,
    // The pane draws a whole-board failure itself, so these are only the failures beside cards that did load.
    sourceFailures: paneState === "failed" ? [] : failureLines,
    moveFailures: [jira.lastMoveFailure, projects.lastMoveFailure].filter(Boolean),
    fieldRequest: request ? { key: request.key, from: request.from.name, to: request.to.name, fields: request.fields.map((f) => ({ id: f.id, name: f.name, kind: f.kind, addedPrefix: f.addedPrefix ?? null })) } : null,
  };
}
