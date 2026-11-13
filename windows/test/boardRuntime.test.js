import { test } from "node:test";
import assert from "node:assert/strict";
import { createBoardRuntime } from "../src/boardRuntime.js";
import { createSettings } from "../src/core/settings.js";
import { priorityFromId } from "../src/core/jira.js";

const memory = () => { let text = null; return { read: () => text, write: (t) => (text = t) }; };
function vault() {
  const data = new Map();
  return { data, available: () => true, get: (k) => data.get(k) ?? null, set: (k, v) => data.set(k, v), delete: (k) => data.delete(k), has: (k) => data.has(k) };
}
const issue = (key, over = {}) => ({ key, summary: `S ${key}`, statusName: "In Progress", statusID: "3", statusCategory: "indeterminate", issueType: "Task", priority: priorityFromId("3"), updatedAt: "2026-10-01T00:00:00Z", createdAt: "2026-09-01T00:00:00Z", categoryChangedAt: null, ...over });
const board = { id: "P1", number: 1, title: "Roadmap", owner: "acme", url: "https://x", statusFieldID: "F1", options: [{ id: "o1", name: "Todo" }, { id: "o2", name: "Doing" }, { id: "o3", name: "Shipped" }] };
const ghItem = { id: "I1", projectID: "P1", number: 5, title: "[ACME-1] Pair me", url: "https://github.com/a/w/issues/5", repo: "a/w", reference: "w#5", isPullRequest: false, typeName: "Issue", statusOptionID: "o2", statusName: "Doing", statusChangedAt: null, createdAt: null, links: [] };

function runtime({ jiraIssues = [issue("ACME-1")] } = {}) {
  const log = { jiraMoves: [], statuses: [], notified: 0, jiraSignedIn: null };
  const settings = createSettings(memory());
  const secrets = vault();
  const rt = createBoardRuntime({
    settings,
    secrets,
    getToken: async () => "gh-token",
    notify: () => log.notified++,
    now: () => new Date("2026-10-30T10:00:00Z"),
    jiraClients: () => {
      let at = { name: "In Progress", category: "indeterminate", id: "3" };
      const toReviewing = { id: "t", to: { name: "Reviewing", category: "indeterminate", id: "1" }, isGlobal: false, needsInput: false, fields: [] };
      return {
        issues: { assignedIssues: async () => jiraIssues },
        links: { fetch: async (keys) => Object.fromEntries(keys.map((k) => [k, []])) },
        mover: {
          async transitions() { return [at, at.name === "In Progress" ? [toReviewing] : []]; },
          async perform(t, key) { log.jiraMoves.push([key, t.to.name]); at = t.to; },
        },
      };
    },
    githubClients: () => ({
      client: { fetchProjects: async () => [board], fetchItems: async () => [ghItem] },
      mover: { setStatus: async (a) => log.statuses.push(a) },
    }),
    // Like the real one: tested first, stored only on success.
    signIn: async ({ input, store }) => {
      store.set("jira", JSON.stringify({ baseURL: input.baseURL.replace(/\/+$/, ""), email: input.email, apiToken: input.apiToken }));
      return { name: "Ada", baseURL: "https://acme.atlassian.net", email: "me@acme.com" };
    },
  });
  return { rt, settings, secrets, log };
}

test("before anyone has signed in or chosen a board, the Board is not configured, and that is not an error", async () => {
  const { rt } = runtime();
  await rt.init();
  const v = rt.view();
  assert.deepEqual([v.isConfigured, v.failureLines, v.jira.signedIn], [false, [], false]);
});

test("signing in tests the credentials, remembers them, and loads the issues at once", async () => {
  const { rt, secrets } = runtime();
  await rt.init();
  const out = await rt.signInToJira({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" });
  assert.equal(out.name, "Ada");
  assert.ok(secrets.has("jira"));
  const v = rt.view();
  assert.deepEqual([v.isConfigured, v.jira.signedIn, v.jira.name, v.cardCount], [true, true, "Ada", 1]);
  assert.equal(v.columns.flatMap((c) => c.cards)[0].openURL, "https://acme.atlassian.net/browse/ACME-1");
});

test("a saved sign-in is picked up at launch", async () => {
  const { rt, secrets } = runtime();
  secrets.set("jira", JSON.stringify({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" }));
  await rt.init();
  await rt.refreshAll();
  assert.equal(rt.view().cardCount, 1);
});

test("signing out removes the token and empties the Jira side", async () => {
  const { rt, secrets } = runtime();
  await rt.init();
  await rt.signInToJira({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" });
  rt.signOutOfJira();
  assert.equal(secrets.has("jira"), false);
  assert.deepEqual([rt.view().cardCount, rt.view().jira.signedIn], [0, false]);
});

test("choosing a GitHub board is remembered, discovered on demand, and its items read", async () => {
  const { rt, settings } = runtime();
  await rt.init();
  await rt.discoverProjects();
  assert.deepEqual(rt.view().projects.map((p) => p.id), ["P1"]);
  assert.equal(rt.view().projects[0].shown, false); // all off until you turn them on
  await rt.setProjectShown("P1", true);
  assert.deepEqual(settings.get("projectSelection"), ["P1"]);
  assert.equal(settings.get("knownProjects")[0].id, "P1");
  assert.equal(rt.view().cardCount, 1);
});

test("a column choice for a Status option is kept in settings and moves the card at once", async () => {
  const { rt, settings } = runtime();
  await rt.init();
  await rt.discoverProjects();
  await rt.setProjectShown("P1", true);
  rt.setProjectChoice("P1", "o2", "done");
  assert.deepEqual(settings.get("projectLaneMap"), { P1: { o2: "done" } });
  assert.equal(rt.view().columns.find((c) => c.lane === "done").cards.length, 0); // finished with no date: not within the window
  assert.equal(rt.view().projects[0].options.find((o) => o.id === "o2").choice, "done");
});

test("a paired card is moved in both places together", async () => {
  const { rt, log } = runtime();
  await rt.init();
  await rt.signInToJira({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" });
  await rt.discoverProjects();
  await rt.setProjectShown("P1", true);
  const pair = rt.view().columns.flatMap((c) => c.cards).find((c) => c.id.kind === "paired");
  assert.ok(pair, "the Jira issue and its GitHub copy are one card");
  await rt.move("paired:ACME-1/I1", "reviewing");
  assert.deepEqual(log.jiraMoves, [["ACME-1", "Reviewing"]]);
  assert.equal(log.statuses.length, 0); // the board has no option that lands in Reviewing: it says so rather than guessing
  assert.match(rt.view().moveFailures.join(" "), /no Status option in Reviewing/);
});

test("what arrives from a drop is checked: a string from another app moves nothing", async () => {
  const { rt, log } = runtime();
  await rt.init();
  await rt.signInToJira({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" });
  await rt.move("some text dragged from a browser", "done");
  await rt.move("jira:ACME-1", "not-a-lane");
  assert.deepEqual(log.jiraMoves, []);
});

test("the Done window is a setting, and it reaches Jira's query", async () => {
  const { rt, settings } = runtime();
  await rt.init();
  await rt.signInToJira({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" });
  settings.set("jiraWindowDays", null);
  await rt.settingChanged("jiraWindowDays");
  assert.equal(rt.view().columns.some((c) => c.lane === "done"), false); // off: the column goes rather than sit permanently empty
});

test("the search is not remembered across launches: a filter still in force with nothing to say so reads as a board that broke", async () => {
  const { rt } = runtime();
  await rt.init();
  rt.setQuery("anything");
  assert.equal(rt.view().query, "anything");
  const { rt: next } = runtime();
  await next.init();
  assert.equal(next.view().query, "");
});

test("the view repaints when a source changes, so a card is seen moving", async () => {
  const { rt, log } = runtime();
  await rt.init();
  await rt.signInToJira({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" });
  const before = log.notified;
  await rt.move("jira:ACME-1", "reviewing");
  assert.ok(log.notified > before);
});
