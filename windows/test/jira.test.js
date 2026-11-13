import { test } from "node:test";
import assert from "node:assert/strict";
import {
  BOARD_LANES, group, guessLane, issueKeyFirst, issueKeyLeading, issueTypeShortName, issueTypeTint, jiraWindowIncludes,
  jiraWindowQualifier, laneOf, matchesSearch, priorityFromId, priorityOrder, searchTerms,
} from "../src/core/jira.js";

// ---- Keys -------------------------------------------------------------------

test("a key is found in a title only for a known Jira project: UTF-8 and RFC-002 are not issues", () => {
  assert.equal(issueKeyFirst("ACME-64471: fix the thing"), "ACME-64471");
  assert.equal(issueKeyFirst("Support UTF-8 and RFC-002"), null);
  assert.equal(issueKeyFirst("UTF-8 then PLAT-12 later"), "PLAT-12");
  assert.equal(issueKeyFirst("no key here"), null);
});

test("the match is exact: a key never matches inside a longer number or word", () => {
  assert.equal(issueKeyFirst("xACME-1"), null);
  assert.equal(issueKeyFirst("ACME-0"), null); // issue numbers start at 1
  assert.equal(issueKeyFirst("(ACME-6023)"), "ACME-6023");
});

test("a GitHub issue migrated from Jira carries its key as a leading [KEY] prefix", () => {
  assert.deepEqual(issueKeyLeading("[ACME-65806] Fix the thing"), { key: "ACME-65806", title: "Fix the thing" });
  assert.deepEqual(issueKeyLeading("  [PLAT-1]   spaced"), { key: "PLAT-1", title: "spaced" });
  assert.equal(issueKeyLeading("[UTF-8] nope"), null);
  assert.equal(issueKeyLeading("Fix [ACME-1] in the middle"), null);
});

// ---- Priority ---------------------------------------------------------------

test("priority sorts by Jira's own ids, and an id this site does not define is unset, never critical", () => {
  assert.deepEqual(["1", "2", "3", "4", "5"].map((id) => priorityFromId(id).name), ["Critical", "High", "Medium", "Low", "Lowest"]);
  assert.equal(priorityFromId("42").name, "None");
  assert.equal(priorityFromId(undefined).name, "None");
  assert.ok(priorityOrder("None") > priorityOrder("Lowest")); // unset sorts last
});

// ---- Columns ----------------------------------------------------------------

const issue = (key, over = {}) => ({ key, summary: `Summary ${key}`, statusName: "In Progress", statusID: null, statusCategory: "indeterminate", issueType: "Task", priority: priorityFromId("3"), updatedAt: "2026-10-01T00:00:00Z", createdAt: "2026-09-01T00:00:00Z", categoryChangedAt: null, ...over });

test("a site's own status ids place a card first", () => {
  assert.equal(laneOf(issue("A-1", { statusID: "10000", statusCategory: "new", statusName: "Whatever" })), "toDo");
  assert.equal(laneOf(issue("A-1", { statusID: "1", statusName: "Open" })), "reviewing");
  assert.equal(laneOf(issue("A-1", { statusID: "6" })), "testing");
  assert.equal(laneOf(issue("A-1", { statusID: "10001", statusCategory: "done" })), "done");
});

test("To do holds parked work too; only startable statuses are on the board", () => {
  const todo = (statusName) => laneOf(issue("A-1", { statusCategory: "new", statusName }));
  assert.deepEqual(["To Do", "todo", "New", " TO DO "].map(todo), ["toDo", "toDo", "toDo", "toDo"]);
  assert.deepEqual(["On Hold", "Awaiting Customer", "Canceled"].map(todo), [null, null, null]);
});

test("inside In progress a status naming review or testing gets its own column, by whole word", () => {
  const inProgress = (statusName, statusCategory = "indeterminate") => laneOf(issue("A-1", { statusName, statusCategory }));
  assert.equal(inProgress("Code Reviewing"), "reviewing");
  assert.equal(inProgress("In Review"), "reviewing");
  assert.equal(inProgress("Testing"), "testing");
  assert.equal(inProgress("In test"), "testing");
  assert.equal(inProgress("Latest build"), "inProgress"); // "test" inside a word is not testing
  assert.equal(inProgress("Contested"), "inProgress");
  assert.equal(inProgress("Reviewing and testing"), "testing"); // testing is later on the road
  assert.equal(inProgress("Whatever", "__unknown"), "inProgress"); // visible and fixable beats hidden
});

test("the lanes are ordered the way work moves", () => {
  assert.deepEqual(BOARD_LANES.map((l) => l.id), ["toDo", "inProgress", "reviewing", "testing", "done"]);
  assert.deepEqual(BOARD_LANES.map((l) => l.title), ["To do", "In progress", "Reviewing", "Testing", "Done"]);
});

// ---- Grouping ---------------------------------------------------------------

const now = new Date("2026-10-30T10:00:00Z");

test("issues are grouped by column and sorted by priority, newest first, then key", () => {
  const groups = group([
    issue("A-3", { priority: priorityFromId("3"), createdAt: "2026-09-01T00:00:00Z" }),
    issue("A-1", { priority: priorityFromId("1"), createdAt: "2026-01-01T00:00:00Z" }),
    issue("A-2", { priority: priorityFromId("3"), createdAt: "2026-09-02T00:00:00Z" }),
    issue("A-4", { priority: priorityFromId("3"), createdAt: "2026-09-02T00:00:00Z" }),
  ], { days: 14, now });
  assert.deepEqual(groups.inProgress.map((i) => i.key), ["A-1", "A-2", "A-4", "A-3"]);
});

test("parked work shows nowhere", () => {
  assert.equal(group([issue("A-1", { statusCategory: "new", statusName: "On Hold" })], { days: 14, now }).toDo.length, 0);
});

test("Done reaches back only as far as the window, judged on when the status category changed", () => {
  const done = (key, changed) => issue(key, { statusCategory: "done", statusName: "Done", categoryChangedAt: changed });
  const issues = [done("A-1", "2026-10-29T00:00:00Z"), done("A-2", "2026-09-01T00:00:00Z"), done("A-3", null)];
  assert.deepEqual(group(issues, { days: 14, now }).done.map((i) => i.key), ["A-1"]); // no date: cannot be shown as recent
  assert.deepEqual(group(issues, { days: null, now }).done, []); // off means off
});

test("Done is newest-finished first", () => {
  const done = (key, changed) => issue(key, { statusCategory: "done", categoryChangedAt: changed });
  const out = group([done("A-1", "2026-10-20T00:00:00Z"), done("A-2", "2026-10-28T00:00:00Z")], { days: 30, now });
  assert.deepEqual(out.done.map((i) => i.key), ["A-2", "A-1"]);
});

test("a card being moved is shown in its target column before Jira confirms", () => {
  const groups = group([issue("A-1")], { days: 14, now, overrides: { "A-1": "done" } });
  assert.deepEqual([groups.inProgress.length, groups.done.map((i) => i.key)], [0, ["A-1"]]); // moving counts as finishing now
});

test("counts and emptiness", () => {
  const groups = group([issue("A-1"), issue("A-2", { statusCategory: "new", statusName: "To Do" })], { days: 14, now });
  assert.equal(groups.count, 2);
  assert.equal(group([], { days: 14, now }).isEmpty, true);
});

// ---- The Done window --------------------------------------------------------

test("the query uses the status category date, not the resolution date", () => {
  assert.equal(jiraWindowQualifier(14), "statusCategoryChangedDate >= -14d");
  assert.equal(jiraWindowQualifier(null), null);
});

test("inclusion is strictly inside the window", () => {
  assert.equal(jiraWindowIncludes(14, "2026-10-16T10:00:00Z", now), false); // exactly at the edge
  assert.equal(jiraWindowIncludes(14, "2026-10-16T10:00:01Z", now), true);
  assert.equal(jiraWindowIncludes(null, "2026-10-29T00:00:00Z", now), false);
  assert.equal(jiraWindowIncludes(14, null, now), false);
});

// ---- Issue types ------------------------------------------------------------

test("types are read by substring, support first; only support is shortened", () => {
  assert.deepEqual(["Customer Support Ticket", "Bug", "Story", "Task", "Epic"].map(issueTypeTint), ["yellow", "red", "green", "blue", "gray"]);
  assert.equal(issueTypeShortName("Customer Support Ticket"), "CST");
  assert.equal(issueTypeShortName(" Bug "), "Bug");
});

// ---- Search -----------------------------------------------------------------

test("search is by words, case and accent blind, so 'extract logic' finds a title that separates them", () => {
  assert.deepEqual(searchTerms("  Extract   LOGIC "), ["extract", "logic"]);
  assert.equal(matchesSearch("ACME-1 Extract the business logic", searchTerms("extract logic")), true);
  assert.equal(matchesSearch("Café menú", searchTerms("cafe menu")), true);
  assert.equal(matchesSearch("anything", searchTerms("")), true);
  assert.equal(matchesSearch("ACME-1 Extract", searchTerms("extract logic")), false);
});

// ---- GitHub Status options --------------------------------------------------

test("a GitHub Status option is placed by its name; not-yet-work starts hidden; unknown lands in progress", () => {
  const lane = (name) => guessLane(name);
  assert.deepEqual(["Todo", "Ready", "Draft", "New", "To do"].map(lane), ["toDo", "toDo", "toDo", "toDo", "toDo"]);
  assert.deepEqual(["In Review", "Reviewing"].map(lane), ["reviewing", "reviewing"]);
  assert.deepEqual(["QA", "Testing"].map(lane), ["testing", "testing"]);
  assert.deepEqual(["Done", "Shipped", "Closed"].map(lane), ["done", "done", "done"]);
  assert.deepEqual(["Backlog", "In Refinement", "Blocked", "On hold", "Canceled"].map(lane), [null, null, null, null, null]);
  assert.deepEqual(["In Progress", "Banana"].map(lane), ["inProgress", "inProgress"]);
});
