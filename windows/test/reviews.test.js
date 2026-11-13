import { test } from "node:test";
import assert from "node:assert/strict";
import {
  REVIEW_LABELS,
  createdQualifier,
  decodeReviewRequests,
  decodeTeams,
  evaluateReviewState,
  fetchReviewRequests,
  fetchTeams,
  includesCreated,
  reviewRequestsQuery,
  reviewRows,
} from "../src/core/reviews.js";

const req = (over = {}) => ({ reviewDecision: null, checks: "SUCCESS", viewerReviewDismissed: false, ...over });

test("a colleague's changes-requested outranks a red build; checks outrank approved", () => {
  assert.equal(evaluateReviewState(req({ reviewDecision: "CHANGES_REQUESTED", checks: "FAILURE" })), "changesRequested");
  assert.equal(evaluateReviewState(req({ reviewDecision: "APPROVED", checks: "FAILURE" })), "checksFailing");
  assert.equal(evaluateReviewState(req({ checks: "ERROR" })), "checksFailing");
  assert.equal(evaluateReviewState(req({ checks: "PENDING" })), "checksPending");
  assert.equal(evaluateReviewState(req({ checks: "EXPECTED" })), "checksPending");
});

test("a repo with no CI is not stuck unreviewable; dismissed, approved, awaiting", () => {
  assert.equal(evaluateReviewState(req({ checks: null })), "awaiting");
  assert.equal(evaluateReviewState(req({ viewerReviewDismissed: true })), "dismissed");
  assert.equal(evaluateReviewState(req({ viewerReviewDismissed: true, checks: "FAILURE" })), "checksFailing");
  assert.equal(evaluateReviewState(req({ reviewDecision: "APPROVED" })), "approved");
  assert.equal(evaluateReviewState(req({ reviewDecision: "REVIEW_REQUIRED" })), "awaiting");
});

test("labels say what the reviewer owes, not what the author waits for", () => {
  assert.equal(REVIEW_LABELS.awaiting, "Needs review"); // not "Waiting for review", which is the author's side
  assert.equal(REVIEW_LABELS.dismissed, "Approval dismissed");
});

const now = new Date("2026-10-30T10:00:00Z");

test("the created qualifier is a full timestamp, and off sends nothing", () => {
  assert.equal(createdQualifier(now, 14), "created:>2026-10-16T10:00:00Z");
  assert.equal(createdQualifier(now, null), null);
});

test("inclusion is strictly inside, matching created:> on both sides of the wire", () => {
  assert.equal(includesCreated("2026-10-16T10:00:00Z", now, 14), false); // exactly at the cutoff
  assert.equal(includesCreated("2026-10-16T10:00:01Z", now, 14), true);
  assert.equal(includesCreated("2026-11-01T00:00:00Z", now, 14), true); // clock trails GitHub's
  assert.equal(includesCreated("2026-10-29T00:00:00Z", now, null), false);
});

const team = (slug, name = slug) => ({ name, combinedSlug: slug });

test("teams: both roles unioned, deduplicated, sorted; a missing scope is an error not 'no teams'", () => {
  const org = (member, admin) => ({ member: { nodes: member }, admin: { nodes: admin } });
  const body = { data: { viewer: { organizations: { nodes: [org([team("Org/zeta"), team("Org/Alpha")], [team("Org/zeta")]), null, org([], [team("Other/beta")])] } } } };
  assert.deepEqual(decodeTeams(body).map((t) => t.combinedSlug), ["Org/Alpha", "Org/zeta", "Other/beta"]);
  assert.deepEqual(decodeTeams({ data: { viewer: { organizations: { nodes: [] } } } }), []);
  assert.throws(() => decodeTeams({ errors: [{ message: "Resource not accessible: read:org" }], data: null }), /read:org/);
});

test("the search: one aliased search per team plus the dismissal one, remote values bound as variables", () => {
  assert.equal(reviewRequestsQuery({ teams: [], disabled: new Set(), windowDays: 14, now }), null);
  assert.equal(reviewRequestsQuery({ teams: [team("Org/a")], disabled: new Set(), windowDays: null, now }), null);

  const { query, variables } = reviewRequestsQuery({ teams: [team("Org/a"), team("Org/b")], disabled: new Set(["Org/b"]), windowDays: 14, now });
  assert.match(query, /s0: search\(query: \$q0, type: ISSUE, first: \$n0\)/);
  assert.match(query, /s1: search/);
  assert.match(query, /\bd: search/);
  assert.doesNotMatch(query, /Org\/a|team-review-requested/);
  assert.match(variables.q0, /team-review-requested:Org\/a -author:@me -reviewed-by:@me created:>2026-10-16T10:00:00Z/);
  assert.match(variables.q0, /is:pr is:open archived:false draft:false/);
  // A switched-off team is still asked, at first: 0, so settings can show what enabling it would cost.
  assert.deepEqual([variables.n0, variables.n1], [20, 0]);
  assert.match(variables.qd, /reviewed-by:@me review:none/);
  assert.equal(variables.nd, 20);
});

test("the dismissal search is skipped when every team is switched off", () => {
  const { variables } = reviewRequestsQuery({ teams: [team("Org/a")], disabled: new Set(["Org/a"]), windowDays: 14, now });
  assert.equal(variables.nd, 0);
});

const node = (id, over = {}) => ({
  id,
  number: 1,
  title: "T",
  url: `https://github.com/acme/w/pull/${id}`,
  headRefOid: "h",
  createdAt: "2026-10-28T00:00:00Z",
  updatedAt: "2026-10-29T00:00:00Z",
  additions: 3,
  deletions: 1,
  changedFiles: 2,
  reviewDecision: null,
  author: { login: "alice" },
  repository: { nameWithOwner: "acme/w", isPrivate: false },
  commits: { nodes: [{ commit: { statusCheckRollup: { state: "SUCCESS" } } }] },
  ...over,
});
const search = (...nodes) => ({ issueCount: nodes.length, nodes });
const teams = [team("Org/a"), team("Org/b")];

test("a PR asked of two teams is one row, carrying both, in the caller's team order", () => {
  const body = { data: { s0: search(node("P1"), node("P2")), s1: search(node("P1")), d: search() } };
  const { requests } = decodeReviewRequests(body, teams);
  assert.equal(requests.length, 2);
  assert.deepEqual(requests.find((r) => r.id === "P1").teams.map((t) => t.combinedSlug), ["Org/a", "Org/b"]);
});

test("newest activity first, not the order the teams were searched", () => {
  const body = { data: { s0: search(node("old", { updatedAt: "2026-10-01T00:00:00Z" })), s1: search(node("new", { updatedAt: "2026-10-29T00:00:00Z" })), d: search() } };
  assert.deepEqual(decodeReviewRequests(body, teams).requests.map((r) => r.id), ["new", "old"]);
});

test("per-team counts come from issueCount; a team GitHub did not answer is absent, not zero", () => {
  const body = { data: { s0: { issueCount: 852, nodes: [] }, s1: null, d: search() } };
  const { pendingCounts } = decodeReviewRequests(body, teams);
  assert.deepEqual(pendingCounts, { "Org/a": 852 });
});

test("a deleted author becomes ghost, and the no-CI case stays null", () => {
  const body = { data: { s0: search(node("P1", { author: null, commits: { nodes: [{ commit: { statusCheckRollup: null } }] } })), s1: search(), d: search() } };
  const [r] = decodeReviewRequests(body, teams).requests;
  assert.equal(r.author, "ghost");
  assert.equal(r.checks, null);
});

const dismissed = (id, slugs, state = "DISMISSED") =>
  node(id, { viewerLatestReview: { state }, timelineItems: { nodes: slugs.map((s) => ({ requestedReviewer: s ? { combinedSlug: s } : {} })) } });

test("a dismissed approval returns as a row, attributed to the team that was asked", () => {
  const body = { data: { s0: search(), s1: search(), d: search(dismissed("D1", ["Org/b", null])) } };
  const [r] = decodeReviewRequests(body, teams).requests;
  assert.equal(r.id, "D1");
  assert.equal(r.viewerReviewDismissed, true);
  assert.deepEqual(r.teams.map((t) => t.combinedSlug), ["Org/b"]);
});

test("dismissal rows that are not dismissals, or that none of the user's teams asked for, are dropped", () => {
  const body = { data: { s0: search(), s1: search(), d: search(dismissed("C1", ["Org/a"], "COMMENTED"), dismissed("D2", ["Someone/else"])) } };
  assert.deepEqual(decodeReviewRequests(body, teams).requests, []);
});

test("a dismissal on a row the team search already found marks that row", () => {
  const body = { data: { s0: search(node("P1")), s1: search(), d: search(dismissed("P1", ["Org/a"])) } };
  const [r] = decodeReviewRequests(body, teams).requests;
  assert.equal(r.viewerReviewDismissed, true);
  assert.equal(decodeReviewRequests(body, teams).requests.length, 1);
});

test("errors behind a 200 are not read as nothing waiting", () => {
  assert.throws(() => decodeReviewRequests({ errors: [{ message: "SAML enforcement" }] }, teams), /SAML/);
});

test("display rows: state label, author, teams, size, age, https links only", () => {
  const body = { data: { s0: search(node("P1", { reviewDecision: "APPROVED" })), s1: search(), d: search() } };
  const { requests } = decodeReviewRequests(body, teams);
  const [row] = reviewRows(requests, now);
  assert.deepEqual(
    { state: row.state, status: row.status, author: row.author, teams: row.teams, size: row.size, age: row.age },
    { state: "approved", status: "Approved already", author: "alice", teams: "Org/a", size: "+3 −1 · 2 files", age: "2 days" },
  );
  assert.deepEqual(reviewRows([{ ...requests[0], url: "file:///x" }], now), []);
});

const replyWith = (json, log = []) => async (url, init) => {
  log.push(JSON.parse(init.body));
  return { ok: true, status: 200, json: async () => json };
};

test("fetchTeams surfaces a missing scope instead of an empty team list", async () => {
  const fetchImpl = replyWith({ errors: [{ message: "Your token has not been granted the required scopes: read:org" }], data: null });
  await assert.rejects(fetchTeams({ token: "t", fetchImpl }), /read:org/);
});

test("fetchReviewRequests makes no request when there is nothing to ask", async () => {
  const log = [];
  const none = await fetchReviewRequests({ token: "t", fetchImpl: replyWith({}, log), teams: [], disabled: new Set(), windowDays: 14, now });
  assert.deepEqual(none, { requests: [], pendingCounts: {} });
  assert.equal(log.length, 0);
});

// A GitHub that answers only the searches switched on (first > 0) in each request.
function githubWithSearches(answers, { failOn } = {}) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const { variables } = JSON.parse(init.body);
    const enabled = Object.keys(variables).filter((k) => k.startsWith("n") && variables[k] > 0).map((k) => k.slice(1));
    calls.push(enabled);
    if (failOn && enabled.includes(failOn)) return { ok: false, status: 502, json: async () => ({}) };
    const data = {};
    for (const alias of Object.keys(answers)) data[alias === "d" ? "d" : `s${alias.slice(1)}`] = enabled.includes(alias.slice(1)) || (alias === "d" && enabled.includes("d")) ? answers[alias] : { issueCount: 0, nodes: [] };
    return { ok: true, status: 200, json: async () => ({ data }) };
  };
  return { fetchImpl, calls };
}

test("each search is its own request: one combined document outruns GitHub's time limit on a big account", async () => {
  const gh = githubWithSearches({ s0: search(node("P1")), s1: search(node("P2")), d: search() });
  const out = await fetchReviewRequests({ token: "t", fetchImpl: gh.fetchImpl, teams: [team("Org/a"), team("Org/b")], disabled: new Set(), windowDays: 14, now });
  assert.deepEqual(gh.calls.map((c) => c.join(",")).sort(), ["0", "1", "d"]); // one search switched on per request
  assert.deepEqual(out.requests.map((r) => r.id).sort(), ["P1", "P2"]);
  assert.deepEqual(out.pendingCounts, { "Org/a": 1, "Org/b": 1 });
});

test("a switched-off team costs no request at all", async () => {
  const gh = githubWithSearches({ s0: search(node("P1")), s1: search(node("P2")), d: search() });
  const out = await fetchReviewRequests({ token: "t", fetchImpl: gh.fetchImpl, teams: [team("Org/a"), team("Org/b")], disabled: new Set(["Org/b"]), windowDays: 14, now });
  assert.deepEqual(gh.calls.map((c) => c.join(",")).sort(), ["0", "d"]);
  assert.deepEqual(out.requests.map((r) => r.id), ["P1"]);
});

test("one search failing fails the section, rather than silently listing a team as empty", async () => {
  const gh = githubWithSearches({ s0: search(node("P1")), d: search() }, { failOn: "0" });
  await assert.rejects(fetchReviewRequests({ token: "t", fetchImpl: gh.fetchImpl, teams: [team("Org/a")], disabled: new Set(), windowDays: 14, now }), /502/);
});
