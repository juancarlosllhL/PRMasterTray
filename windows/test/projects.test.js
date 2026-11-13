import { test } from "node:test";
import assert from "node:assert/strict";
import {
  LaneMap, ProjectScopeError, decodeIssueLinks, decodeItems, decodeLogin, decodeProjects, decodeStatusUpdate,
  fetchProjectItems, fetchProjects, issueLinksQuery, linkedPullRequestId, setProjectStatus,
} from "../src/core/projects.js";

// ---- Which column a Status option lands in ----------------------------------

const project = (over = {}) => ({ id: "P1", number: 1, title: "Board", owner: "acme", url: "https://github.com/orgs/acme/projects/1", statusFieldID: "F1", options: [{ id: "o1", name: "Todo" }, { id: "o2", name: "In Review" }, { id: "o3", name: "Shipped" }, { id: "o4", name: "Backlog" }], ...over });

test("an option is placed by its name unless the user chose otherwise", () => {
  const map = new LaneMap();
  assert.equal(map.lane("o1", "Todo", "P1"), "toDo");
  assert.equal(map.lane("o2", "In Review", "P1"), "reviewing");
  assert.equal(map.lane("o4", "Backlog", "P1"), null); // not yet work: hidden
});

test("an item with no Status at all is not yet triaged, so it starts hidden", () => {
  assert.equal(new LaneMap().lane(null, null, "P1"), null);
  assert.equal(new LaneMap().choice(null, null, "P1"), "hidden");
});

test("a choice is kept by option id, so renaming a column on GitHub keeps it", () => {
  const map = new LaneMap();
  map.set("done", "o4", "P1");
  assert.equal(map.lane("o4", "Backlog", "P1"), "done");
  assert.equal(map.lane("o4", "Renamed to Whatever", "P1"), "done");
  assert.equal(map.lane("o4", "Backlog", "OTHER"), null); // per project
});

test("items with no Status can be given a column of their own choosing", () => {
  const map = new LaneMap();
  map.set("toDo", "", "P1"); // the empty option id stands for "no Status"
  assert.equal(map.lane(null, null, "P1"), "toDo");
});

test("a move lands on the option named like the column, or else the first that lands there", () => {
  const map = new LaneMap();
  const p = project({ options: [{ id: "a", name: "Ready" }, { id: "b", name: "To do" }, { id: "c", name: "In Review" }] });
  assert.equal(map.target("toDo", p).id, "b"); // named like the column
  assert.equal(map.target("reviewing", p).id, "c");
  assert.equal(map.target("done", p), null); // a column with no option says so rather than guessing
  map.set("done", "a", "P1");
  assert.equal(map.target("done", p).id, "a");
});

test("the map persists as plain data", () => {
  const map = new LaneMap({ P1: { o4: "done" } });
  assert.deepEqual(map.toJSON(), { P1: { o4: "done" } });
});

// ---- Discovering boards -----------------------------------------------------

const projNode = (id, over = {}) => ({ id, number: 1, title: `Project ${id}`, url: `https://github.com/orgs/acme/projects/${id}`, closed: false, owner: { login: "acme" }, field: { id: "F", options: [{ id: "o1", name: "Todo" }] }, ...over });

test("every open board found by any route is listed once, sorted by title", () => {
  const body = { data: { viewer: {
    projectsV2: { nodes: [projNode("b", { title: "beta" }), projNode("a", { title: "Alpha" })] },
    organizations: { nodes: [{ recentProjects: { nodes: [projNode("a", { title: "Alpha" }), projNode("c", { title: "closed one", closed: true })] }, projects: { nodes: [projNode("d", { title: "delta" }), null] } }, null] },
  } } };
  assert.deepEqual(decodeProjects(body).map((p) => p.title), ["Alpha", "beta", "delta"]);
});

test("a board with no single-select Status field has no columns to map", () => {
  const [p] = decodeProjects({ data: { viewer: { projectsV2: { nodes: [projNode("x", { field: {} })] }, organizations: { nodes: [] } } } });
  assert.deepEqual([p.statusFieldID, p.options], [null, []]);
});

test("a missing scope is named for what it is, not read as no boards", () => {
  const body = { errors: [{ type: "INSUFFICIENT_SCOPES", message: "Your token has not been granted the required scopes: requires one of ['read:project'], but your token has only been granted: ['repo']. 'project'" }], data: null };
  assert.throws(() => decodeProjects(body), ProjectScopeError);
  assert.throws(() => decodeProjects(body), /gh auth refresh/);
  assert.throws(() => decodeProjects({ errors: [{ message: "boom" }] }), /boom/);
});

test("the viewer's login", () => {
  assert.equal(decodeLogin({ data: { viewer: { login: "ada" } } }), "ada");
});

// ---- Items ------------------------------------------------------------------

const itemNode = (id, content, status = { optionId: "o1", name: "Todo", updatedAt: "2026-10-29T10:00:00Z" }) => ({ id, status, content });
const issue = (over = {}) => ({ __typename: "Issue", number: 7, title: "Fix it", url: "https://github.com/acme/w/issues/7", createdAt: "2026-10-01T00:00:00Z", issueType: { name: "Bug" }, repository: { nameWithOwner: "acme/w" }, closedByPullRequestsReferences: { nodes: [{ id: "PR_1", number: 9, title: "Fix", url: "https://github.com/acme/w/pull/9", state: "MERGED", isDraft: false, repository: { nameWithOwner: "acme/w", isPrivate: false } }, null] }, ...over });
const page = (nodes, hasNextPage = false) => ({ data: { node: { items: { pageInfo: { hasNextPage, endCursor: hasNextPage ? "c1" : null }, nodes } } } });

test("an issue item carries its repo, type, Status and the pull requests that close it", () => {
  const { items, next } = decodeItems(page([itemNode("I1", issue())]), "P1");
  assert.equal(next, null);
  assert.deepEqual({ ...items[0], links: undefined }, { id: "I1", projectID: "P1", number: 7, title: "Fix it", url: "https://github.com/acme/w/issues/7", repo: "acme/w", isPullRequest: false, typeName: "Bug", statusOptionID: "o1", statusName: "Todo", statusChangedAt: "2026-10-29T10:00:00Z", createdAt: "2026-10-01T00:00:00Z", links: undefined });
  assert.deepEqual(items[0].links.map((l) => [l.number, l.state, l.repo]), [[9, "MERGED", "acme/w"]]);
});

test("a pull request item has no links of its own and its own default type name", () => {
  const { items } = decodeItems(page([itemNode("I2", { __typename: "PullRequest", number: 3, title: "T", url: "https://github.com/acme/w/pull/3", createdAt: "2026-10-01T00:00:00Z", repository: { nameWithOwner: "acme/w" } })]), "P1");
  assert.deepEqual([items[0].isPullRequest, items[0].typeName, items[0].links], [true, "Pull request", []]);
  assert.equal(decodeItems(page([itemNode("I3", issue({ issueType: null }))]), "P1").items[0].typeName, "Issue");
});

test("drafts and redacted items are not items: there is nothing to link to", () => {
  const out = decodeItems(page([itemNode("D1", { __typename: "DraftIssue", title: "Note" }), itemNode("R1", null), null, itemNode("I1", issue())]), "P1");
  assert.deepEqual(out.items.map((i) => i.id), ["I1"]);
});

test("an item with no Status keeps null option and name", () => {
  const { items } = decodeItems(page([itemNode("I1", issue(), null)]), "P1");
  assert.deepEqual([items[0].statusOptionID, items[0].statusName, items[0].statusChangedAt], [null, null, null]);
});

test("a page says where the next one starts, and a node that is not a board is an error", () => {
  assert.equal(decodeItems(page([], true), "P1").next, "c1");
  assert.throws(() => decodeItems({ data: { node: null } }), /no items/);
});

test("the reference is the repository's name without its owner, as GitHub writes one", () => {
  const { items } = decodeItems(page([itemNode("I1", issue())]), "P1");
  assert.equal(items[0].reference, "w#7");
});

test("moving an item needs GitHub to confirm it", () => {
  decodeStatusUpdate({ data: { updateProjectV2ItemFieldValue: { projectV2Item: { id: "I1" } } } });
  assert.throws(() => decodeStatusUpdate({ data: { updateProjectV2ItemFieldValue: { projectV2Item: null } } }), /never confirmed/);
});

// ---- Over the wire ----------------------------------------------------------

function github(handler) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push(body);
    return { ok: true, status: 200, json: async () => handler(body, calls.length) };
  };
  return { calls, fetchImpl };
}

test("boards are asked for on all three routes in one query", async () => {
  const gh = github(() => ({ data: { viewer: { projectsV2: { nodes: [projNode("a")] }, organizations: { nodes: [] } } } }));
  const out = await fetchProjects({ token: "t", fetchImpl: gh.fetchImpl });
  assert.equal(out.length, 1);
  assert.match(gh.calls[0].query, /recentProjects/);
  assert.match(gh.calls[0].query, /projectsV2\(first: 20, orderBy/);
});

test("items are filtered on GitHub's side by the viewer's login, and paged up to a cap", async () => {
  const gh = github((body) => {
    if (body.query.includes("viewer { login }")) return { data: { viewer: { login: "ada" } } };
    return page([itemNode(`I${body.variables.after ?? "0"}`, issue())], true); // never ends
  });
  const items = await fetchProjectItems({ token: "t", fetchImpl: gh.fetchImpl, projectID: "P1", login: "ada" });
  assert.equal(items.length, 5); // five pages, then stop: a runaway board cannot spin
  assert.equal(gh.calls[0].variables.q, "assignee:ada");
  assert.equal(gh.calls[1].variables.after, "c1");
});

test("a scope the token lacks is retried once with a fresh token, as `gh auth refresh` can hand one out", async () => {
  let attempts = 0;
  const tokens = [];
  const out = await fetchProjects({
    token: async () => { tokens.push(++attempts); return `t${attempts}`; },
    fetchImpl: async (url, init) => {
      const t = init.headers.Authorization;
      return { ok: true, status: 200, json: async () => (t === "Bearer t1" ? { errors: [{ type: "INSUFFICIENT_SCOPES", message: "needs 'project'" }], data: null } : { data: { viewer: { projectsV2: { nodes: [projNode("a")] }, organizations: { nodes: [] } } } }) };
    },
  });
  assert.equal(out.length, 1);
  assert.equal(tokens.length, 2);
});

test("setting a Status sends every id as a variable", async () => {
  const gh = github(() => ({ data: { updateProjectV2ItemFieldValue: { projectV2Item: { id: "I1" } } } }));
  await setProjectStatus({ token: "t", fetchImpl: gh.fetchImpl, project: "P1", item: "I1", field: "F1", option: "o2" });
  assert.deepEqual(gh.calls[0].variables, { project: "P1", item: "I1", field: "F1", option: "o2" });
  assert.match(gh.calls[0].query, /singleSelectOptionId: \$option/);
});

// ---- Pull requests carrying a Jira key --------------------------------------

test("one document asks for every key, each as a variable, scoped to the user's own pull requests", () => {
  assert.equal(issueLinksQuery([]), null);
  const { query, variables } = issueLinksQuery(["ACME-1", "ACME-2", "ACME-1"]);
  assert.deepEqual(variables, { q0: "ACME-1 in:title is:pr author:@me", q1: "ACME-2 in:title is:pr author:@me" }); // deduplicated
  assert.match(query, /k0: search\(query: \$q0/);
  assert.doesNotMatch(query, /ACME-/);
});

test("too many keys for one document is refused, not silently truncated", () => {
  const keys = Array.from({ length: 21 }, (_, i) => `ACME-${i + 1}`);
  assert.equal(issueLinksQuery(keys), null);
  assert.ok(issueLinksQuery(keys.slice(0, 20)));
});

test("each key gets its pull requests; a key with no hits is empty rather than absent", () => {
  const node = (n, state = "OPEN") => ({ id: `PR_${n}`, number: n, title: `T${n}`, url: `https://github.com/acme/w/pull/${n}`, state, isDraft: false, repository: { nameWithOwner: "acme/w", isPrivate: true } });
  const out = decodeIssueLinks({ data: { k0: { nodes: [node(1), node(2, "WEIRD"), null] }, k1: { nodes: [] }, k2: null } }, ["ACME-1", "ACME-2", "ACME-3"]);
  assert.deepEqual(out["ACME-1"].map((l) => [l.number, l.state]), [[1, "OPEN"], [2, "OPEN"]]); // an unrecognised state must not read as shipped
  assert.deepEqual([out["ACME-2"], out["ACME-3"]], [[], []]);
});

test("an error behind a 200 is not read as nothing linked", () => {
  assert.throws(() => decodeIssueLinks({ errors: [{ message: "SAML" }] }, ["ACME-1"]), /SAML/);
});

test("a reference that is unambiguous across repositories", () => {
  assert.equal(linkedPullRequestId("acme/w", 675), "acme/w#675");
});
