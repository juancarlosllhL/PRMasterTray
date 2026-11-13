import { test } from "node:test";
import assert from "node:assert/strict";
import {
  JiraError, JiraField, assignedQuery, createCredentials, createJiraClient, jiraDate, moveIssue, nextHop,
} from "../src/core/jiraApi.js";

// ---- Credentials ------------------------------------------------------------

test("credentials are trimmed and checked where they are typed, with a reason", () => {
  const c = createCredentials({ baseURL: " https://acme.atlassian.net/// ", email: " me@acme.com ", apiToken: " tok " });
  assert.deepEqual([c.baseURL, c.email], ["https://acme.atlassian.net", "me@acme.com"]);
  assert.equal(c.basicAuthHeader, `Basic ${Buffer.from("me@acme.com:tok").toString("base64")}`);
  assert.throws(() => createCredentials({ baseURL: "http://acme.atlassian.net", email: "a@b", apiToken: "t" }), /https:\/\//);
  assert.throws(() => createCredentials({ baseURL: "https://", email: "a@b", apiToken: "t" }), /https:\/\//);
  assert.throws(() => createCredentials({ baseURL: "https://x.y", email: "nope", apiToken: "t" }), /email/);
  assert.throws(() => createCredentials({ baseURL: "https://x.y", email: "a@b", apiToken: "  " }), /token is empty/);
});

test("the token is never in a credential's description or JSON", () => {
  const c = createCredentials({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "super-secret" });
  assert.equal(String(c).includes("super-secret"), false);
  assert.equal(JSON.stringify(c).includes("super-secret"), false);
  assert.equal(JSON.stringify({ c }).includes("super-secret"), false);
});

// ---- The query --------------------------------------------------------------

test("the search is everything open, plus what reached Done inside the window", () => {
  assert.equal(assignedQuery(14), "assignee = currentUser() AND (statusCategory != Done OR statusCategoryChangedDate >= -14d) ORDER BY updated DESC");
  assert.equal(assignedQuery(null), "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC");
});

test("Jira's date has an offset with no colon; it is read as the instant it names", () => {
  assert.equal(jiraDate("2026-09-10T08:00:00.000+0000"), "2026-09-10T08:00:00.000Z");
  assert.equal(jiraDate("2026-09-10T10:00:00.000+0200"), "2026-09-10T08:00:00.000Z");
  assert.equal(jiraDate("garbage"), null);
  assert.equal(jiraDate(undefined), null);
});

// ---- A Jira over HTTP -------------------------------------------------------

const node = (key, over = {}) => ({
  key,
  fields: { summary: `S ${key}`, status: { id: "3", name: "In Progress", statusCategory: { key: "indeterminate" } }, issuetype: { id: "10002", name: "Task" }, updated: "2026-10-01T10:00:00.000+0000", created: "2026-09-01T10:00:00.000+0000", priority: { id: "2" }, statuscategorychangedate: "2026-10-01T10:00:00.000+0000", ...over },
});

function jira(handler) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    const out = await handler(new URL(url), init, calls.length);
    return { ok: out.status < 300, status: out.status ?? 200, json: async () => out.json ?? {}, text: async () => JSON.stringify(out.json ?? {}) };
  };
  const credentials = createCredentials({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" });
  return { calls, client: createJiraClient({ credentials, fetchImpl }) };
}

test("assigned issues are read page by page until Jira says it is the last", async () => {
  const { client, calls } = jira((url) => {
    const token = url.searchParams.get("nextPageToken");
    return { json: token ? { issues: [node("ACME-2")], isLast: true } : { issues: [node("ACME-1")], isLast: false, nextPageToken: "p2" } };
  });
  const issues = await client.assignedIssues(14);
  assert.deepEqual(issues.map((i) => i.key), ["ACME-1", "ACME-2"]);
  assert.equal(calls.length, 2);
  const first = new URL(calls[0].url);
  assert.equal(first.pathname, "/rest/api/3/search/jql"); // the old /search answers 410
  assert.equal(first.searchParams.get("maxResults"), "100");
  assert.equal(first.searchParams.get("fields"), "key,summary,status,issuetype,updated,created,priority,statuscategorychangedate");
  assert.equal(calls[0].init.headers.Authorization.startsWith("Basic "), true);
  assert.equal(calls[0].init.headers["User-Agent"], "PRMaster");
});

test("an issue decodes with its status category key, priority by id, and dates as instants", async () => {
  const { client } = jira(() => ({ json: { issues: [node("ACME-1")], isLast: true } }));
  const [i] = await client.assignedIssues(14);
  assert.deepEqual({ key: i.key, statusName: i.statusName, statusID: i.statusID, statusCategory: i.statusCategory, issueType: i.issueType, priority: i.priority.name, updatedAt: i.updatedAt }, { key: "ACME-1", statusName: "In Progress", statusID: "3", statusCategory: "indeterminate", issueType: "Task", priority: "High", updatedAt: "2026-10-01T10:00:00.000Z" });
});

test("missing pieces are tolerated: unknown category, no priority, no dates", async () => {
  const { client } = jira(() => ({ json: { issues: [{ key: "ACME-9", fields: {} }], isLast: true } }));
  const [i] = await client.assignedIssues(null);
  assert.deepEqual([i.statusCategory, i.priority.name, i.summary, i.createdAt], ["__unknown", "None", "", null]);
});

test("verifying names who the credentials belong to", async () => {
  const { client } = jira(() => ({ json: { displayName: "Ada Lovelace" } }));
  assert.equal(await client.verify(), "Ada Lovelace");
  const { client: bad } = jira(() => ({ json: {} }));
  await assert.rejects(bad.verify(), /displayName/);
});

test("what Jira's statuses mean: 401/403 is a bad sign-in, 429 a wait, the rest an HTTP error", async () => {
  const code = async (status) => {
    const { client } = jira(() => ({ status }));
    try { await client.assignedIssues(14); } catch (e) { return e.code; }
    return null;
  };
  assert.equal(await code(401), "unauthorized");
  assert.equal(await code(403), "unauthorized");
  assert.equal(await code(429), "rateLimited");
  assert.equal(await code(500), "http");
});

// ---- Transitions ------------------------------------------------------------

const transitionsBody = (over = {}) => ({
  fields: { status: { id: "3", name: "In Progress", statusCategory: { key: "indeterminate" } }, issuetype: { id: "10002", name: "Task" } },
  transitions: [
    { id: "21", to: { id: "1", name: "Reviewing", statusCategory: { key: "indeterminate" } }, isGlobal: false, fields: {} },
    { id: "31", to: { id: "10002", name: "Parked", statusCategory: { key: "new" } }, isGlobal: true, fields: { resolution: { required: true, name: "Resolution", schema: {} } } },
  ],
  ...over,
});

test("transitions are read for the issue's current status, with the screens they open", async () => {
  const { client, calls } = jira(() => ({ json: transitionsBody() }));
  const [status, transitions] = await client.transitions("ACME-1");
  assert.deepEqual([status.name, status.category, status.id], ["In Progress", "indeterminate", "3"]);
  assert.deepEqual(transitions.map((t) => [t.id, t.to.name, t.isGlobal, t.needsInput]), [["21", "Reviewing", false, false], ["31", "Parked", true, true]]);
  const url = new URL(calls[0].url);
  assert.equal(url.pathname, "/rest/api/3/issue/ACME-1");
  assert.equal(url.searchParams.get("expand"), "transitions.fields");
});

test("a required field the app cannot fill makes the hop impossible; one it can is asked for", async () => {
  const body = transitionsBody({
    transitions: [{ id: "41", to: { id: "6", name: "Testing", statusCategory: { key: "indeterminate" } }, isGlobal: false, fields: {
      customfield_1: { required: true, name: "Root cause", schema: { custom: "com.atlassian.jira.plugin.system.customfieldtypes:select" }, allowedValues: [{ value: "Code" }, { name: "Config" }] },
      customfield_2: { required: true, name: "Remark", schema: { custom: "com.atlassian.jira.plugin.system.customfieldtypes:textarea" } },
      customfield_3: { required: false, name: "Notes", schema: { custom: "x:textfield" } },
      customfield_4: { required: true, name: "Weird", schema: { custom: "x:cascadingselect" } },
    } }],
  });
  const { client } = jira(() => ({ json: body }));
  const [, [t]] = await client.transitions("ACME-1");
  assert.equal(t.needsInput, true); // customfield_4 is required and of a kind the app cannot ask for
  assert.deepEqual(t.fields.map((f) => [f.id, f.kind.type]), [["customfield_1", "option"], ["customfield_2", "richText"]]);
  assert.deepEqual(t.fields[0].kind.allowed, ["Code", "Config"]);
});

test("on the Bug workflow every askable field is asked, because a validator demands what Jira calls optional", async () => {
  const body = transitionsBody({
    fields: { status: { id: "3", name: "In Progress", statusCategory: { key: "indeterminate" } }, issuetype: { id: "10004", name: "Bug" } },
    transitions: [{ id: "41", to: { id: "6", name: "Testing", statusCategory: { key: "indeterminate" } }, isGlobal: false, fields: { f1: { required: false, name: "Root cause", schema: { custom: "x:textfield" } } } }],
  });
  const { client } = jira(() => ({ json: body }));
  const [, [t]] = await client.transitions("ACME-1");
  assert.deepEqual(t.fields.map((f) => f.id), ["f1"]);
});

test("a response with no status is refused", async () => {
  const { client } = jira(() => ({ json: { fields: {}, transitions: [] } }));
  await assert.rejects(client.transitions("ACME-1"), /no status/);
});

test("the key lands in a URL path, so only a real key is accepted", async () => {
  const { client, calls } = jira(() => ({ json: transitionsBody() }));
  for (const bad of ["../../etc", "ACME-1/transitions", "acme-1", "ACME-", "A B-1"]) {
    await assert.rejects(client.transitions(bad), /not a Jira issue key/, bad);
  }
  assert.equal(calls.length, 0);
});

test("performing a transition posts its id and the values for its fields, in the shape Jira wants", async () => {
  const { client, calls } = jira(() => ({ status: 204 }));
  const transition = { id: "41", fields: [{ id: "f_opt", kind: { type: "option", allowed: ["Code"] } }, { id: "f_txt", kind: { type: "text" } }, { id: "f_rich", kind: { type: "richText" } }] };
  await client.perform(transition, "ACME-1", { f_opt: "Code", f_txt: "short", f_rich: "line one\n\nline three", ignored: "x" });
  const sent = JSON.parse(calls[0].init.body);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(new URL(calls[0].url).pathname, "/rest/api/3/issue/ACME-1/transitions");
  assert.deepEqual(sent.transition, { id: "41" });
  assert.deepEqual(sent.fields.f_opt, { value: "Code" });
  assert.equal(sent.fields.f_txt, "short");
  assert.deepEqual(sent.fields.f_rich, { type: "doc", version: 1, content: [
    { type: "paragraph", content: [{ type: "text", text: "line one" }] },
    { type: "paragraph", content: [] },
    { type: "paragraph", content: [{ type: "text", text: "line three" }] },
  ] });
  assert.equal("ignored" in sent.fields, false);
});

test("a move Jira refuses says why, in Jira's own words; for a move a 403 is not a bad token", async () => {
  const { client } = jira(() => ({ status: 400, json: { errorMessages: ["Transition not valid."], errors: { resolution: "Resolution is required." } } }));
  await assert.rejects(client.perform({ id: "1", fields: [] }, "ACME-1", {}), (e) => e.code === "moveRefused" && e.message === "Transition not valid. Resolution is required.");
  const { client: forbidden } = jira(() => ({ status: 403, json: { errorMessages: ["You do not have permission."] } }));
  await assert.rejects(forbidden.perform({ id: "1", fields: [] }, "ACME-1", {}), { code: "moveRefused" });
  const { client: empty } = jira(() => ({ status: 409 }));
  await assert.rejects(empty.perform({ id: "1", fields: [] }, "ACME-1", {}), /HTTP 409/);
});

// ---- Fields -----------------------------------------------------------------

const field = (name, kind) => new JiraField({ id: name.toLowerCase(), name, kind });

test("a Remark opens with PM: unless it already does, whatever its case", () => {
  const remark = field("Remark", { type: "richText" });
  assert.equal(remark.normalized("  fixed it "), "PM: fixed it");
  assert.equal(remark.normalized("pm: done"), "PM: done");
  assert.equal(remark.normalized("PM:done"), "PM:done");
  assert.equal(remark.addedPrefix, "PM:");
  assert.equal(field("Notes", { type: "text" }).addedPrefix, null);
});

test("a field is required: empty or prefix-only text, or an option outside the allowed ones, is a problem", () => {
  const remark = field("Remark", { type: "richText" });
  assert.equal(remark.problem("   "), "Remark is required.");
  assert.equal(remark.problem("PM:"), "Remark is required.");
  assert.equal(remark.problem("did it"), null);
  const cause = field("Cause", { type: "option", allowed: ["Code", "Config"] });
  assert.equal(cause.problem("Code"), null);
  assert.equal(cause.problem("Nope"), "Choose a Cause.");
  assert.equal(cause.problem(""), "Choose a Cause.");
});

// ---- Choosing the next step -------------------------------------------------

const status = (name, category, id = null) => ({ name, category, id });
const hop = (id, toName, toCategory, extra = {}) => ({ id, to: status(toName, toCategory, extra.toID ?? null), isGlobal: false, needsInput: false, fields: [], ...extra });

test("a step that arrives is taken, preferring the one named like the column, then a non-global one", () => {
  const here = status("In Progress", "indeterminate", "3");
  const offered = [hop("a", "Review Done", "indeterminate", { toID: "1", isGlobal: true }), hop("b", "Reviewing", "indeterminate", { toID: "1" }), hop("c", "In Review", "indeterminate", { toID: "1" })];
  assert.equal(nextHop(here, "reviewing", offered, new Set()).id, "b"); // the name matches the column
  assert.equal(nextHop(here, "reviewing", offered.filter((t) => t.id !== "b"), new Set()).id, "c"); // else a non-global one
  assert.equal(nextHop(here, "reviewing", [offered[0]], new Set()).id, "a"); // else whatever arrives
});

test("with no direct step, the one that gets closest is taken; a step away from the target never is", () => {
  const here = status("To Do", "new", "10000");
  const offered = [hop("up", "In Progress", "indeterminate", { toID: "3" }), hop("far", "Done", "done", { toID: "10001" })];
  assert.equal(nextHop(here, "reviewing", offered, new Set()).id, "up");
  const inReview = status("Reviewing", "indeterminate", "1");
  assert.equal(nextHop(inReview, "toDo", [hop("fwd", "Testing", "indeterminate", { toID: "6" })], new Set()), null);
});

test("it never takes a step that needs input, revisits a status, or parks the issue", () => {
  const here = status("In Progress", "indeterminate", "3");
  assert.equal(nextHop(here, "reviewing", [hop("n", "Reviewing", "indeterminate", { toID: "1", needsInput: true })], new Set()), null);
  assert.equal(nextHop(here, "reviewing", [hop("v", "Reviewing", "indeterminate", { toID: "1" })], new Set(["Reviewing"])), null);
  // Parked: global, and not a status that names a column.
  assert.equal(nextHop(here, "reviewing", [hop("p", "On Hold", "new", { isGlobal: true })], new Set()), null);
  // A status with no column of its own (parked) is not a place to start from either.
  assert.equal(nextHop(status("On Hold", "new"), "inProgress", [hop("x", "In Progress", "indeterminate", { toID: "3" })], new Set()), null);
});

test("a global step is allowed when it names a column, as Cancel does on some sites", () => {
  const here = status("Reviewing", "indeterminate", "1");
  assert.equal(nextHop(here, "done", [hop("g", "Done", "done", { toID: "10001", isGlobal: true })], new Set()).id, "g");
});

// ---- Walking to a column ----------------------------------------------------

function workflow(steps, { askFor, failAt } = {}) {
  const performed = [];
  let at = steps.start;
  const client = {
    async transitions() {
      return [at, steps.offered[at.name] ?? []];
    },
    async perform(transition, key, values) {
      if (failAt === transition.id) throw new JiraError("moveRefused", "Jira says no.");
      performed.push([transition.id, values]);
      at = transition.to;
    },
  };
  return { client, performed, move: (target) => moveIssue({ client, askFor }, "ACME-1", target) };
}

const flow = {
  start: status("To Do", "new", "10000"),
  offered: {
    "To Do": [hop("t1", "In Progress", "indeterminate", { toID: "3" })],
    "In Progress": [hop("t2", "Reviewing", "indeterminate", { toID: "1" })],
    Reviewing: [hop("t3", "Testing", "indeterminate", { toID: "6", fields: [{ id: "remark", name: "Remark", kind: { type: "richText" }, normalized: (v) => `PM: ${v}` }] })],
  },
};

test("a card is walked through the steps in between, re-reading the status before each", async () => {
  const w = workflow(flow);
  const outcome = await w.move("reviewing");
  assert.deepEqual(w.performed.map((p) => p[0]), ["t1", "t2"]);
  assert.deepEqual([outcome.kind, outcome.to.name], ["moved", "Reviewing"]);
});

test("already in the column: nothing to do", async () => {
  const w = workflow({ ...flow, start: status("Reviewing", "indeterminate", "1") });
  assert.equal((await w.move("reviewing")).kind, "moved");
  assert.equal(w.performed.length, 0);
});

test("a step that opens a form asks for its fields first; closing the form cancels where the walk had got to", async () => {
  const asked = [];
  const answered = workflow({ ...flow, start: status("Reviewing", "indeterminate", "1") }, { askFor: async (request) => (asked.push(request), { remark: "done" }) });
  assert.equal((await answered.move("testing")).kind, "moved");
  assert.deepEqual(answered.performed, [["t3", { remark: "done" }]]);
  assert.equal(asked[0].key, "ACME-1");

  const cancelled = workflow({ ...flow, start: status("In Progress", "indeterminate", "3") }, { askFor: async () => null });
  const outcome = await cancelled.move("testing");
  assert.deepEqual([outcome.kind, outcome.leftAt.name], ["cancelled", "Reviewing"]);
});

test("a hop Jira refuses stops the walk and names where it left the issue", async () => {
  const w = workflow(flow, { failAt: "t2" });
  const outcome = await w.move("reviewing");
  assert.deepEqual([outcome.kind, outcome.message, outcome.leftAt.name], ["failed", "Jira says no.", "In Progress"]);
});

test("with no way forward the walk stops where it is, and says which column it was after", async () => {
  const w = workflow({ start: status("To Do", "new", "10000"), offered: { "To Do": [] } });
  const outcome = await w.move("done");
  assert.deepEqual([outcome.kind, outcome.at.name, outcome.target], ["stopped", "To Do", "done"]);
});

test("a workflow that loops is cut off after six hops", async () => {
  let n = 0;
  const loop = (name) => [hop(`l${n++}`, `${name}+`, "indeterminate", { toID: "3" })]; // never arrives, never repeats a name
  const client = {
    async transitions() { return [status(`S${n}`, "indeterminate", "3"), loop(`S${n}`)]; },
    async perform() {},
  };
  const outcome = await moveIssue({ client }, "ACME-1", "done");
  assert.equal(outcome.kind, "stopped");
  assert.ok(n <= 7, `took ${n} hops`);
});
