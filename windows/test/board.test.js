import { test } from "node:test";
import assert from "node:assert/strict";
import { cardIdFrom, cardIdToString, columnsOf, composeBoard } from "../src/core/board.js";
import { priorityFromId } from "../src/core/jira.js";

const now = new Date("2026-10-30T10:00:00Z");

// ---- Card ids ---------------------------------------------------------------

test("card ids round-trip, and a string dropped from another app is nothing", () => {
  for (const id of [{ kind: "jira", key: "ACME-1" }, { kind: "project", item: "PVTI_1" }, { kind: "paired", key: "ACME-1", item: "PVTI_1" }]) {
    assert.deepEqual(cardIdFrom(cardIdToString(id)), id);
  }
  assert.equal(cardIdToString({ kind: "paired", key: "ACME-1", item: "I1" }), "paired:ACME-1/I1");
  for (const junk of ["", "jira", "jira:", "other:1", "paired:ACME-1", "paired:/x", "hello world"]) assert.equal(cardIdFrom(junk), null, junk);
});

// ---- Fixtures ---------------------------------------------------------------

const issue = (key, over = {}) => ({ key, summary: `Summary ${key}`, statusName: "In Progress", statusID: null, statusCategory: "indeterminate", issueType: "Task", priority: priorityFromId("3"), updatedAt: "2026-10-01T00:00:00Z", createdAt: "2026-09-01T00:00:00Z", categoryChangedAt: null, ...over });
const proj = { id: "P1", title: "Roadmap", options: [{ id: "o1", name: "Todo" }, { id: "o2", name: "Doing" }, { id: "o3", name: "Shipped" }] };
const item = (id, over = {}) => ({ id, projectID: "P1", number: 5, title: "GH issue", url: "https://github.com/acme/w/issues/5", repo: "acme/w", reference: "w#5", isPullRequest: false, typeName: "Issue", statusOptionID: "o2", statusName: "Doing", statusChangedAt: "2026-10-29T00:00:00Z", createdAt: "2026-09-10T00:00:00Z", links: [], ...over });
const link = (n, over = {}) => ({ id: `PR_${n}`, number: n, title: `T${n}`, url: `https://github.com/acme/w/pull/${n}`, repo: "acme/w", isPrivate: false, isDraft: false, state: "OPEN", ...over });

const board = (over = {}) =>
  composeBoard({
    issues: [], jiraMoves: {}, jiraLinks: {}, jiraLinkState: () => "unknown",
    items: [], projects: [proj], projectLane: (i) => ({ o1: "toDo", o2: "inProgress", o3: "done" })[i.statusOptionID] ?? null, itemMoves: {},
    windowDays: 14, now, ...over,
  });
const all = (b) => Object.values(b).flat();

// ---- Jira cards -------------------------------------------------------------

test("a Jira issue is a card on its column, copied by its key, tinted by its category", () => {
  const b = board({ issues: [issue("ACME-1"), issue("ACME-2", { statusCategory: "new", statusName: "To Do" })], jiraLinkState: () => "none" });
  const card = b.inProgress[0];
  assert.deepEqual({ id: card.id, sources: card.sources, reference: card.reference, copyID: card.copyID, title: card.title, statusName: card.statusName, typeName: card.typeName, tint: card.tint, lane: card.lane, url: card.url, linkState: card.linkState }, { id: { kind: "jira", key: "ACME-1" }, sources: [{ kind: "jira" }], reference: "ACME-1", copyID: "ACME-1", title: "Summary ACME-1", statusName: "In Progress", typeName: "Task", tint: "blue", lane: "inProgress", url: null, linkState: "none" });
  assert.equal(b.toDo[0].tint, "gray");
});

test("a Jira card carries the pull requests found for its key", () => {
  const b = board({ issues: [issue("ACME-1")], jiraLinks: { "ACME-1": [link(9)] } });
  assert.deepEqual(b.inProgress[0].links.map((l) => l.number), [9]);
});

test("parked work shows nowhere, and Done is held to the window", () => {
  const b = board({ issues: [issue("ACME-1", { statusCategory: "new", statusName: "On Hold" }), issue("ACME-2", { statusCategory: "done", statusName: "Done", categoryChangedAt: "2026-05-01T00:00:00Z" })] });
  assert.equal(all(b).length, 0);
});

// ---- GitHub cards -----------------------------------------------------------

test("a GitHub item is a card by its Status, copied as owner/repo#n, with no priority of its own", () => {
  const b = board({ items: [item("I1")] });
  const card = b.inProgress[0];
  assert.deepEqual({ id: card.id, reference: card.reference, copyID: card.copyID, statusName: card.statusName, priority: card.priority.name, tint: card.tint, url: card.url, linkState: card.linkState, sources: card.sources }, { id: { kind: "project", item: "I1" }, reference: "w#5", copyID: "acme/w#5", statusName: "Doing", priority: "None", tint: "blue", url: "https://github.com/acme/w/issues/5", linkState: "none", sources: [{ kind: "github", project: "Roadmap" }] });
});

test("an item whose Status maps to a hidden column is not on the board", () => {
  assert.equal(all(board({ items: [item("I1", { statusOptionID: "o9", statusName: "Backlog" })] })).length, 0);
});

test("a GitHub issue says whether pull requests close it; a pull request has nothing to look up", () => {
  assert.equal(board({ items: [item("I1", { links: [link(1)] })] }).inProgress[0].linkState, "linked");
  assert.equal(board({ items: [item("I1", { isPullRequest: true })] }).inProgress[0].linkState, null);
});

test("the status shown is the board's current name for the option, so a renamed column is not stale", () => {
  const renamed = { ...proj, options: [{ id: "o2", name: "Underway" }] };
  assert.equal(board({ items: [item("I1")], projects: [renamed] }).inProgress[0].statusName, "Underway");
  assert.equal(board({ items: [item("I1", { statusOptionID: null, statusName: null })], projectLane: () => "toDo" }).toDo[0].statusName, "No Status");
});

test("GitHub's Done is held to the window by when the Status was set; a card being moved counts as finishing now", () => {
  const done = (id, changed) => item(id, { statusOptionID: "o3", statusName: "Shipped", statusChangedAt: changed });
  const b = board({ items: [done("I1", "2026-10-29T00:00:00Z"), done("I2", "2026-05-01T00:00:00Z"), done("I3", null)] });
  assert.deepEqual(b.done.map((c) => c.id.item), ["I1"]);
  const moving = board({ items: [done("I4", "2026-05-01T00:00:00Z")], itemMoves: { I4: "done" } });
  assert.deepEqual(moving.done.map((c) => c.id.item), ["I4"]);
  assert.equal(board({ items: [done("I1", "2026-10-29T00:00:00Z")], windowDays: null }).done.length, 0);
});

// ---- Pairs ------------------------------------------------------------------

test("a GitHub issue migrated from Jira and its Jira original are one card, with both sources", () => {
  const b = board({
    issues: [issue("ACME-65806", { issueType: "Bug", priority: priorityFromId("1"), createdAt: "2026-02-01T00:00:00Z" })],
    items: [item("I1", { title: "[ACME-65806] Fix the thing", createdAt: "2026-10-01T00:00:00Z" })],
    jiraLinks: { "ACME-65806": [link(9)] },
  });
  assert.equal(all(b).length, 1); // not two
  const card = all(b)[0];
  assert.deepEqual({ id: card.id, sources: card.sources, reference: card.reference, pairedReference: card.pairedReference, title: card.title, typeName: card.typeName, priority: card.priority.name, createdAt: card.createdAt, url: card.url, copyID: card.copyID, lane: card.lane }, { id: { kind: "paired", key: "ACME-65806", item: "I1" }, sources: [{ kind: "jira" }, { kind: "github", project: "Roadmap" }], reference: "ACME-65806", pairedReference: "w#5", title: "Fix the thing", typeName: "Bug", priority: "Critical", createdAt: "2026-02-01T00:00:00Z", url: "https://github.com/acme/w/issues/5", copyID: "acme/w#5", lane: "inProgress" }); // GitHub places and opens it; Jira supplies priority, type and age
});

test("a pair whose two sides disagree on the column says so in its status", () => {
  const agree = board({ issues: [issue("ACME-1")], items: [item("I1", { title: "[ACME-1] x" })] });
  assert.equal(all(agree)[0].statusName, "Doing");
  const differ = board({ issues: [issue("ACME-1", { statusName: "Reviewing", statusID: "1" })], items: [item("I1", { title: "[ACME-1] x" })] });
  assert.equal(all(differ)[0].statusName, "Doing · Jira: Reviewing");
});

test("a pair's pull requests are Jira's first, then GitHub's that Jira did not find, once each", () => {
  const b = board({ issues: [issue("ACME-1")], items: [item("I1", { title: "[ACME-1] x", links: [link(9), link(10)] })], jiraLinks: { "ACME-1": [link(9), link(8)] } });
  assert.deepEqual(all(b)[0].links.map((l) => l.number), [9, 8, 10]);
});

test("a pull request titled with a key keeps its own card: the key names the work, not a copy", () => {
  const b = board({ issues: [issue("ACME-1")], items: [item("I1", { title: "[ACME-1] fix", isPullRequest: true })] });
  assert.equal(all(b).length, 2);
});

test("only the first copy of an issue pairs; a second stays a card of its own", () => {
  const b = board({ issues: [issue("ACME-1")], items: [item("I1", { title: "[ACME-1] a" }), item("I2", { title: "[ACME-1] b", number: 6, reference: "w#6" })] });
  assert.deepEqual(all(b).map((c) => c.id.kind).sort(), ["paired", "project"]);
});

test("a paired card is not drawn again as the Jira issue it came from", () => {
  const b = board({ issues: [issue("ACME-1"), issue("ACME-2")], items: [item("I1", { title: "[ACME-1] x" })] });
  assert.deepEqual(all(b).map((c) => c.reference).sort(), ["ACME-1", "ACME-2"]);
});

// ---- Ordering, columns and search -------------------------------------------

test("cards are ordered by priority, then newest, then reference; Done by when it finished", () => {
  const b = board({
    issues: [issue("A-3", { priority: priorityFromId("3") }), issue("A-1", { priority: priorityFromId("1"), createdAt: "2026-01-01T00:00:00Z" }), issue("A-2", { priority: priorityFromId("3"), createdAt: "2026-09-02T00:00:00Z" })],
    items: [item("I1", { statusOptionID: "o3", statusChangedAt: "2026-10-20T00:00:00Z", reference: "w#1" }), item("I2", { statusOptionID: "o3", statusChangedAt: "2026-10-28T00:00:00Z", reference: "w#2" })],
  });
  assert.deepEqual(b.inProgress.map((c) => c.reference), ["A-1", "A-2", "A-3"]);
  assert.deepEqual(b.done.map((c) => c.reference), ["w#2", "w#1"]);
});

test("the columns are the five lanes in order; Done goes when its window is off, an empty one stays otherwise", () => {
  const b = board();
  assert.deepEqual(columnsOf(b, { windowDays: 14, query: "" }).map((c) => c.title), ["To do", "In progress", "Reviewing", "Testing", "Done"]);
  assert.deepEqual(columnsOf(b, { windowDays: null, query: "" }).map((c) => c.title), ["To do", "In progress", "Reviewing", "Testing"]);
  assert.equal(columnsOf(b, { windowDays: 14, query: "" }).every((c) => c.cards.length === 0), true);
});

test("the search is by words over reference, paired reference and title; Done shows no priority", () => {
  const b = board({ issues: [issue("ACME-1", { summary: "Extract the business logic" })], items: [item("I1", { title: "Unrelated card" })] });
  assert.deepEqual(columnsOf(b, { windowDays: 14, query: "extract logic" }).flatMap((c) => c.cards).map((c) => c.reference), ["ACME-1"]);
  assert.deepEqual(columnsOf(b, { windowDays: 14, query: "w#5" }).flatMap((c) => c.cards).map((c) => c.reference), ["w#5"]);
  assert.equal(columnsOf(b, { windowDays: 14, query: "" }).find((c) => c.lane === "done").showsPriority, false);
  assert.equal(columnsOf(b, { windowDays: 14, query: "" }).find((c) => c.lane === "toDo").showsPriority, true);
});
