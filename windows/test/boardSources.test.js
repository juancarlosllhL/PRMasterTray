import { test } from "node:test";
import assert from "node:assert/strict";
import { JiraSource, ProjectSource } from "../src/core/boardSources.js";
import { priorityFromId } from "../src/core/jira.js";

const now = () => new Date("2026-10-30T10:00:00Z");
const issue = (key, over = {}) => ({ key, summary: `S ${key}`, statusName: "In Progress", statusID: "3", statusCategory: "indeterminate", issueType: "Task", priority: priorityFromId("3"), updatedAt: "2026-10-01T00:00:00Z", createdAt: "2026-09-01T00:00:00Z", categoryChangedAt: null, ...over });
const link = (n) => ({ id: `PR_${n}`, number: n, title: `T${n}`, url: `https://github.com/a/w/pull/${n}`, repo: "a/w", isPrivate: false, isDraft: false, state: "OPEN" });

// ---- Jira -------------------------------------------------------------------

function jiraSource({ issues = [issue("ACME-1")], links = async (keys) => Object.fromEntries(keys.map((k) => [k, []])), mover = null, windowDays = 14 } = {}) {
  const calls = { fetch: 0, links: [] };
  const source = new JiraSource({
    issues: { assignedIssues: async (w) => { calls.fetch++; return typeof issues === "function" ? issues(calls.fetch) : issues; } },
    links: { fetch: async (keys) => { calls.links.push(keys); return links(keys); } },
    mover,
    now,
    windowDays,
  });
  return { source, calls };
}

test("a refresh lists the assigned issues, leaving epics out: they are other people's work", async () => {
  const { source } = jiraSource({ issues: [issue("ACME-1"), issue("ACME-2", { issueType: "Epic" })] });
  await source.refresh();
  assert.deepEqual(source.issues.map((i) => i.key), ["ACME-1"]);
  assert.equal(source.lastError, null);
  assert.ok(source.lastSuccessfulFetch);
});

test("until someone signs in there is nothing to fetch, and that is not a failure", async () => {
  const source = new JiraSource({ issues: null, links: null, now, windowDays: 14 });
  await source.refresh();
  assert.deepEqual([source.isConfigured, source.lastError, source.issues], [false, null, []]);
});

test("a failed refresh keeps the last good list and says so", async () => {
  let fail = false;
  const { source } = jiraSource({ issues: () => { if (fail) throw new Error("down"); return [issue("ACME-1")]; } });
  await source.refresh();
  fail = true;
  await source.refresh();
  assert.deepEqual(source.issues.map((i) => i.key), ["ACME-1"]);
  assert.equal(source.lastError.message, "down");
  assert.equal(source.consecutiveFailures, 1);
});

test("the poll backs off while Jira keeps failing, and recovers after one good answer", async () => {
  let fail = true;
  const { source } = jiraSource({ issues: () => { if (fail) throw new Error("down"); return []; } });
  const waits = [];
  for (let i = 0; i < 4; i++) { await source.refresh(); waits.push(source.pollIntervalMs); }
  assert.deepEqual(waits, [120_000, 300_000, 300_000, 300_000]);
  fail = false;
  await source.refresh();
  assert.equal(source.pollIntervalMs, 60_000);
});

test("one issue is told apart from four states: looking up, could not look up, none, found", async () => {
  let release;
  const gate = new Promise((r) => (release = r));
  const { source } = jiraSource({ issues: [issue("A-1"), issue("A-2"), issue("A-3")], links: async (keys) => { await gate; return { "A-1": [link(1)], "A-2": [], "A-3": [] }; } });
  const running = source.refresh();
  await new Promise((r) => setImmediate(r));
  assert.equal(source.linkState("A-1"), "loading");
  release();
  await running;
  assert.deepEqual(["A-1", "A-2", "A-3"].map((k) => source.linkState(k)), ["linked", "none", "none"]);
});

test("a failed lookup reads as unknown rather than as none, and does not raise the stale banner over a good list", async () => {
  const { source } = jiraSource({ issues: [issue("A-1")], links: async () => { throw new Error("search down"); } });
  await source.refresh();
  assert.equal(source.linkState("A-1"), "unknown");
  assert.equal(source.lastLinkFailure, "search down");
  assert.equal(source.lastError, null);
});

test("keys are looked up in chunks, so a long list cannot build a document GitHub refuses", async () => {
  const many = Array.from({ length: 45 }, (_, i) => issue(`ACME-${i + 1}`));
  const { source, calls } = jiraSource({ issues: many });
  await source.refresh();
  assert.deepEqual(calls.links.map((c) => c.length), [20, 20, 5]);
});

test("only the keys that answered are replaced: a failed chunk leaves its issues unknown, not empty", async () => {
  const many = Array.from({ length: 25 }, (_, i) => issue(`ACME-${i + 1}`));
  let calls = 0;
  const { source } = jiraSource({ issues: many, links: async (keys) => { if (++calls === 2) throw new Error("chunk failed"); return Object.fromEntries(keys.map((k) => [k, [link(1)]])); } });
  await source.refresh();
  assert.equal(source.linkState("ACME-1"), "linked");
  assert.equal(source.linkState("ACME-25"), "unknown");
});

// ---- Moving a Jira card -----------------------------------------------------

const reviewing = { name: "Reviewing", category: "indeterminate", id: "1" };

function mover({ status = { name: "In Progress", category: "indeterminate", id: "3" }, offered = [], failWith = null } = {}) {
  let at = status;
  return {
    async transitions() { return [at, offered]; },
    async perform(t) { if (failWith) throw new Error(failWith); at = t.to; },
  };
}
const toReviewing = { id: "t", to: reviewing, isGlobal: false, needsInput: false, fields: [] };

test("a card goes to its column at once, and the override outlives only the fetches that started before Jira confirmed", async () => {
  const { source } = jiraSource({ mover: mover({ offered: [toReviewing] }) });
  await source.refresh();
  const moving = source.move("ACME-1", "reviewing");
  await moving;
  assert.equal(source.lastMoveFailure, null);
  // The refresh that ends a move started after Jira confirmed, so it is new enough to replace the override.
  assert.deepEqual(Object.keys(source.moves), []);
});

test("while a move is in flight the card already shows in its target column", async () => {
  let release;
  const gate = new Promise((r) => (release = r));
  const slow = { async transitions() { await gate; return [{ name: "In Progress", category: "indeterminate", id: "3" }, [toReviewing]]; }, async perform() {} };
  const { source } = jiraSource({ mover: slow });
  await source.refresh();
  const moving = source.move("ACME-1", "reviewing");
  assert.equal(source.laneOf(source.issues[0]), "reviewing");
  assert.equal(source.isMoving("ACME-1"), true);
  release();
  await moving;
});

test("a confirmed move patches the issue so the board is right before the next poll", async () => {
  let fetched = 0;
  const { source } = jiraSource({ issues: () => (fetched++ === 0 ? [issue("ACME-1")] : [issue("ACME-1")]), mover: mover({ offered: [toReviewing] }) });
  await source.refresh();
  // Hold the final refresh out of the way: look at the patch itself.
  source.refresh = async () => {};
  await source.move("ACME-1", "reviewing");
  const patched = source.issues[0];
  assert.deepEqual([patched.statusName, patched.statusID, patched.statusCategory], ["Reviewing", "1", "indeterminate"]);
  assert.equal(source.moves["ACME-1"].lane, "reviewing");
  assert.equal(source.moves["ACME-1"].settledAfter, source.refreshGeneration); // kept until a later fetch confirms it
});

test("each way a move can end leaves a plain message, and the card goes back", async () => {
  const run = async (m) => {
    const { source } = jiraSource({ mover: m });
    await source.refresh();
    await source.move("ACME-1", "testing");
    return { source, message: source.lastMoveFailure };
  };
  const stuck = await run(mover({ offered: [] }));
  assert.equal(stuck.message, "ACME-1 stopped at In Progress. Jira offers no way on from there to Testing.");
  assert.deepEqual(Object.keys(stuck.source.moves), []);

  const refused = await run(mover({ offered: [toReviewing], failWith: "Transition not valid." }));
  assert.equal(refused.message, "Couldn't move ACME-1 — Transition not valid.");
});

test("a move that got part of the way names where it left the issue", async () => {
  let performed = 0;
  const m = {
    async transitions() { return performed === 0 ? [{ name: "In Progress", category: "indeterminate", id: "3" }, [toReviewing]] : [reviewing, [{ id: "x", to: { name: "Testing", category: "indeterminate", id: "6" }, isGlobal: false, needsInput: false, fields: [] }]]; },
    async perform() { if (++performed === 2) throw new Error("No permission."); },
  };
  const { source } = jiraSource({ mover: m });
  await source.refresh();
  await source.move("ACME-1", "testing");
  assert.equal(source.lastMoveFailure, "Couldn't move ACME-1 past Reviewing — No permission.");
});

test("without a mover (fixtures) nothing can be written; a card already there, or already moving, is left alone", async () => {
  const { source } = jiraSource({ mover: null });
  await source.refresh();
  assert.equal(source.canMove, false);
  await source.move("ACME-1", "reviewing");
  assert.deepEqual(Object.keys(source.moves), []);

  const { source: here } = jiraSource({ mover: mover() });
  await here.refresh();
  await here.move("ACME-1", "inProgress"); // already there
  assert.equal(here.lastMoveFailure, null);
});

test("a hop that needs a form opens it, waits for the answer, and sends what was normalised", async () => {
  const remark = { id: "remark", name: "Remark", kind: { type: "richText" }, normalized: (v) => `PM: ${v}`, problem: (v) => (v.trim() ? null : "Remark is required.") };
  const withForm = { ...toReviewing, fields: [remark] };
  const performed = [];
  let at = { name: "In Progress", category: "indeterminate", id: "3" };
  const m = { async transitions() { return [at, at.name === "In Progress" ? [withForm] : []]; }, async perform(t, key, values) { performed.push(values); at = t.to; } };
  const { source } = jiraSource({ mover: m });
  await source.refresh();
  source.refresh = async () => {};
  const moving = source.move("ACME-1", "reviewing");
  await new Promise((r) => setImmediate(r));
  assert.equal(source.fieldRequest.key, "ACME-1");
  source.submitFields({ remark: "   " }); // refused: still open
  assert.ok(source.fieldRequest);
  source.submitFields({ remark: "done" });
  await moving;
  assert.deepEqual(performed, [{ remark: "PM: done" }]);
  assert.equal(source.fieldRequest, null);
});

test("closing the form cancels the move, and names where the issue was left if it got anywhere", async () => {
  const remark = { id: "remark", name: "Remark", kind: { type: "text" }, normalized: (v) => v, problem: () => null };
  const m = { async transitions() { return [{ name: "In Progress", category: "indeterminate", id: "3" }, [{ ...toReviewing, fields: [remark] }]]; }, async perform() {} };
  const { source } = jiraSource({ mover: m });
  await source.refresh();
  const moving = source.move("ACME-1", "reviewing");
  await new Promise((r) => setImmediate(r));
  source.cancelFields();
  await moving;
  assert.equal(source.lastMoveFailure, null); // nothing had happened yet: nothing to report
  assert.deepEqual(Object.keys(source.moves), []);
});

test("signing out or in drops what was in flight: a move from the old session lands nowhere", async () => {
  let release;
  const gate = new Promise((r) => (release = r));
  const slow = { async transitions() { await gate; return [reviewing, []]; }, async perform() {} };
  const { source } = jiraSource({ mover: slow });
  await source.refresh();
  const moving = source.move("ACME-1", "reviewing");
  source.connect(null);
  release();
  await moving;
  assert.deepEqual([source.issues, source.moves, source.isConfigured], [[], {}, false]);
});

// ---- GitHub Projects --------------------------------------------------------

const board = (over = {}) => ({ id: "P1", number: 1, title: "Roadmap", owner: "acme", url: "https://x", statusFieldID: "F1", options: [{ id: "o1", name: "Todo" }, { id: "o2", name: "Doing" }, { id: "o3", name: "Shipped" }], ...over });
const item = (id, over = {}) => ({ id, projectID: "P1", number: 5, title: "T", url: "https://github.com/a/w/issues/5", repo: "a/w", reference: "w#5", isPullRequest: false, typeName: "Issue", statusOptionID: "o2", statusName: "Doing", statusChangedAt: "2026-10-29T00:00:00Z", createdAt: "2026-09-01T00:00:00Z", links: [], ...over });

function projectSource({ projects = [board()], items = { P1: [item("I1")] }, selection = ["P1"], mover = { setStatus: async () => {} }, saved = {} } = {}) {
  const persisted = [];
  const source = new ProjectSource({
    client: { fetchProjects: async () => projects, fetchItems: async (id) => { const out = items[id]; if (out instanceof Error) throw out; return out ?? []; } },
    mover,
    known: projects,
    selection,
    laneMap: saved.laneMap ?? {},
    persist: (what, value) => persisted.push([what, value]),
    now,
    windowDays: 14,
  });
  return { source, persisted };
}

test("only selected boards with a Status field are shown: one without has no columns", () => {
  const { source } = projectSource({ projects: [board(), board({ id: "P2" }), board({ id: "P3", statusFieldID: null, options: [] })], selection: ["P1", "P3"] });
  assert.deepEqual(source.shownProjects.map((p) => p.id), ["P1"]);
  assert.equal(source.isConfigured, true);
  assert.equal(projectSource({ selection: [] }).source.isConfigured, false);
});

test("a refresh reads every shown board; one that fails keeps its last items so it cannot empty the others", async () => {
  const items = { P1: [item("I1")], P2: [item("I2", { projectID: "P2" })] };
  const { source } = projectSource({ projects: [board(), board({ id: "P2" })], items, selection: ["P1", "P2"] });
  await source.refresh();
  assert.deepEqual(source.items.map((i) => i.id).sort(), ["I1", "I2"]);
  items.P2 = new Error("P2 down");
  await source.refresh();
  assert.deepEqual(source.items.map((i) => i.id).sort(), ["I1", "I2"]); // P2's last items stay
  assert.equal(source.lastError.message, "P2 down");
  assert.ok(source.lastSuccessfulFetch);
});

test("a board GitHub stopped listing is kept if it is selected: recent projects rotate out, a chosen one must not", async () => {
  const { source, persisted } = projectSource({ projects: [board(), board({ id: "P2" })], selection: ["P1"] });
  source.client.fetchProjects = async () => [board({ id: "P9" })];
  await source.discover();
  assert.deepEqual(source.projects.map((p) => p.id), ["P9", "P1"]);
  assert.deepEqual(persisted.at(-1)[0], "projects");
});

test("a failed discovery leaves the known boards usable", async () => {
  const { source } = projectSource();
  source.client.fetchProjects = async () => { throw new Error("no scope"); };
  await source.discover();
  assert.equal(source.discoveryError.message, "no scope");
  assert.equal(source.projects.length, 1);
});

test("turning a board off drops its items and persists the choice", async () => {
  const { source, persisted } = projectSource();
  await source.refresh();
  await source.setShown("P1", false);
  assert.deepEqual([source.items, source.isConfigured], [[], false]);
  assert.deepEqual(persisted.at(-1), ["selection", []]);
});

test("an item's column is the map's reading of its option's current name, or its move's target", async () => {
  const { source } = projectSource();
  await source.refresh();
  assert.equal(source.laneOf(source.items[0]), "inProgress");
  source.setChoice("done", "o2", "P1");
  assert.equal(source.laneOf(source.items[0]), "done");
});

test("moving sets the Status option that lands in the column, patches the item, and settles", async () => {
  const sent = [];
  const { source } = projectSource({ mover: { setStatus: async (a) => sent.push(a) } });
  await source.refresh();
  source.refresh = async () => {};
  await source.move("I1", "done");
  assert.deepEqual(sent, [{ project: "P1", item: "I1", field: "F1", option: "o3" }]);
  assert.deepEqual([source.items[0].statusOptionID, source.items[0].statusName], ["o3", "Shipped"]);
  assert.equal(source.moves.I1.settledAfter, source.refreshGeneration);
});

test("a column with no option mapped says so rather than guessing, and nothing is sent", async () => {
  const sent = [];
  const { source } = projectSource({ mover: { setStatus: async (a) => sent.push(a) } });
  await source.refresh();
  await source.move("I1", "testing");
  assert.equal(source.lastMoveFailure, "Roadmap has no Status option in Testing. Map one under Settings, Board.");
  assert.equal(sent.length, 0);
});

test("a refused move goes back and says why", async () => {
  const { source } = projectSource({ mover: { setStatus: async () => { throw new Error("Resource not accessible."); } } });
  await source.refresh();
  await source.move("I1", "done");
  assert.equal(source.lastMoveFailure, "Couldn't move w#5 — Resource not accessible.");
  assert.deepEqual(Object.keys(source.moves), []);
});

test("without a mover nothing is written to GitHub", async () => {
  const { source } = projectSource({ mover: null });
  await source.refresh();
  assert.equal(source.canMove, false);
  await source.move("I1", "done");
  assert.deepEqual(Object.keys(source.moves), []);
});
