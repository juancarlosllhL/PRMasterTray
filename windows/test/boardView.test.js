import { test } from "node:test";
import assert from "node:assert/strict";
import { boardView, resolvePane } from "../src/core/boardView.js";
import { JiraSource, ProjectSource } from "../src/core/boardSources.js";
import { priorityFromId } from "../src/core/jira.js";

const now = () => new Date("2026-10-30T10:00:00Z");

// ---- What a pane draws ------------------------------------------------------

test("rows first, so a failed refresh never blanks a list already on screen; then the error, so a first failure cannot sit on Loading", () => {
  const at = new Date();
  assert.equal(resolvePane({ rowCount: 3, hiddenCount: 0, lastError: null, lastSuccessfulFetch: at }), "content");
  assert.equal(resolvePane({ rowCount: 3, hiddenCount: 0, lastError: new Error("x"), lastSuccessfulFetch: at }), "stale");
  assert.equal(resolvePane({ rowCount: 0, hiddenCount: 0, lastError: new Error("x"), lastSuccessfulFetch: null }), "failed");
  assert.equal(resolvePane({ rowCount: 0, hiddenCount: 0, lastError: null, lastSuccessfulFetch: null }), "loading");
  assert.equal(resolvePane({ rowCount: 0, hiddenCount: 4, lastError: null, lastSuccessfulFetch: at }), "emptyByFilter");
  assert.equal(resolvePane({ rowCount: 0, hiddenCount: 0, lastError: null, lastSuccessfulFetch: at }), "empty");
});

// ---- The board --------------------------------------------------------------

const issue = (key, over = {}) => ({ key, summary: `S ${key}`, statusName: "In Progress", statusID: "3", statusCategory: "indeterminate", issueType: "Task", priority: priorityFromId("3"), updatedAt: "2026-10-01T00:00:00Z", createdAt: "2026-09-01T00:00:00Z", categoryChangedAt: null, ...over });
const proj = { id: "P1", title: "Roadmap", statusFieldID: "F1", options: [{ id: "o2", name: "Doing" }] };
const item = (id) => ({ id, projectID: "P1", number: 5, title: "GH", url: "https://github.com/a/w/issues/5", repo: "a/w", reference: "w#5", isPullRequest: false, typeName: "Issue", statusOptionID: "o2", statusName: "Doing", statusChangedAt: null, createdAt: null, links: [] });

async function sources({ jiraIssues = [issue("ACME-1")], jiraFails = false, ghItems = [item("I1")], ghFails = false, signedIn = true, projectsOn = true } = {}) {
  const jira = new JiraSource({ issues: signedIn ? { assignedIssues: async () => { if (jiraFails) throw new Error("Jira down"); return jiraIssues; } } : null, links: null, mover: {}, now, windowDays: 14 });
  const projects = new ProjectSource({ client: { fetchProjects: async () => [proj], fetchItems: async () => { if (ghFails) throw new Error("GitHub down"); return ghItems; } }, mover: {}, known: [proj], selection: projectsOn ? ["P1"] : [], now, windowDays: 14 });
  await jira.refresh();
  await projects.refresh();
  return { jira, projects };
}
const view = (s, over = {}) => boardView({ ...s, windowDays: 14, query: "", siteURL: "https://acme.atlassian.net", now: now(), ...over });

test("cards from both sources land in shared columns, each openable and movable", async () => {
  const v = view(await sources());
  const cards = v.columns.flatMap((c) => c.cards);
  assert.deepEqual(cards.map((c) => c.reference).sort(), ["ACME-1", "w#5"]);
  const jira = cards.find((c) => c.reference === "ACME-1");
  assert.equal(jira.openURL, "https://acme.atlassian.net/browse/ACME-1"); // Jira's link needs the signed-in site
  assert.equal(jira.canMove, true);
  assert.equal(cards.find((c) => c.reference === "w#5").openURL, "https://github.com/a/w/issues/5");
  assert.equal(v.paneState, "content");
  assert.equal(v.isConfigured, true);
});

test("nothing configured is not an error: the board offers to be set up", async () => {
  const v = view(await sources({ signedIn: false, projectsOn: false }));
  assert.deepEqual([v.isConfigured, v.paneState, v.failureLines], [false, "loading", []]);
});

test("one source failing beside cards that did load says so on a line of its own", async () => {
  const v = view(await sources({ jiraFails: true }));
  assert.equal(v.paneState, "content"); // a failure beside cards that did load is not a failed pane
  assert.deepEqual(v.sourceFailures, ["Couldn't reach Jira — Jira down"]);
  assert.equal(v.columns.flatMap((c) => c.cards).length, 1); // GitHub's card is still there
});

test("every source failing, with nothing to show, is a failed pane that names each reason", async () => {
  const v = view(await sources({ jiraFails: true, ghFails: true }));
  assert.equal(v.paneState, "failed");
  assert.deepEqual(v.failureLines, ["Couldn't reach Jira — Jira down", "Couldn't reach GitHub Projects — GitHub down"]);
  assert.deepEqual(v.sourceFailures, []); // the pane draws a whole-board failure itself
});

test("an empty Jira says nothing about a GitHub board that never answered", async () => {
  const v = view(await sources({ jiraIssues: [], ghFails: true }));
  assert.equal(v.paneState, "failed");
});

test("loading until each source has answered one way or the other", async () => {
  const jira = new JiraSource({ issues: { assignedIssues: async () => [] }, links: null, mover: null, now, windowDays: 14 });
  const v = view({ jira, projects: new ProjectSource({ client: null, now, windowDays: 14 }) });
  assert.equal(v.paneState, "loading");
});

test("the search narrows what is drawn but not the tab's badge, and says when it hides everything", async () => {
  const s = await sources();
  const v = view(s, { query: "nothing matches this" });
  assert.deepEqual([v.visibleCount, v.cardCount], [0, 2]);
  assert.equal(v.paneState, "emptyByFilter");
});

test("a card being moved is flagged, so the board can show it in motion", async () => {
  const s = await sources();
  s.jira.moves["ACME-1"] = { lane: "reviewing", settledAfter: null };
  const cards = view(s).columns.flatMap((c) => c.cards);
  const moving = cards.find((c) => c.reference === "ACME-1");
  assert.deepEqual([moving.moving, moving.lane], [true, "reviewing"]);
});

test("move failures from both sources are collected, and the form a hop opened is passed on", async () => {
  const s = await sources();
  s.jira.lastMoveFailure = "Couldn't move ACME-1 — no";
  s.projects.lastMoveFailure = "Couldn't move w#5 — no";
  s.jira.fieldRequest = { key: "ACME-1", from: { name: "A" }, to: { name: "B" }, fields: [{ id: "f", name: "Remark", kind: { type: "richText" }, addedPrefix: "PM:" }] };
  const v = view(s);
  assert.deepEqual(v.moveFailures, ["Couldn't move ACME-1 — no", "Couldn't move w#5 — no"]);
  assert.deepEqual(v.fieldRequest, { key: "ACME-1", from: "A", to: "B", fields: [{ id: "f", name: "Remark", kind: { type: "richText" }, addedPrefix: "PM:" }] });
});

test("a pull request on a card is offered with its own link and state, under the privacy filter", async () => {
  const s = await sources({ ghItems: [{ ...item("I1"), links: [{ id: "PR_1", number: 9, title: "Fix", url: "https://github.com/a/w/pull/9", repo: "a/w", isPrivate: true, isDraft: false, state: "MERGED" }] }] });
  const card = view(s).columns.flatMap((c) => c.cards).find((c) => c.reference === "w#5");
  assert.deepEqual(card.links.map((l) => [l.number, l.state]), [[9, "MERGED"]]);
  const hidden = view(s, { filter: { includes: (l) => !l.isPrivate } }).columns.flatMap((c) => c.cards).find((c) => c.reference === "w#5");
  assert.deepEqual(hidden.links, []);
});

test("each card carries its own drag/copy id as a string, ready for a drop", async () => {
  const s = await sources();
  const ids = view(s).columns.flatMap((c) => c.cards).map((c) => c.idString).sort();
  assert.deepEqual(ids, ["jira:ACME-1", "project:I1"]);
});
