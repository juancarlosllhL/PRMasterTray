// Pull requests a team of yours has been asked to review. Port of
// ReviewRequest.swift, ReviewState.swift, ReviewWindow.swift, TeamFilter.swift and
// the review half of Queries.swift / GraphQLResponse.swift.
import { assertNoErrors, document, post } from "./graphql.js";
import { ageLabel } from "./staleness.js";

const DAY_MS = 86_400_000;
const PAGE_SIZE = 20;
const DISMISSAL = "d";

// Its own answer rather than a reuse of Readiness: `behind` and `conflicted` are
// things the *author* acts on, and every row here would read "Waiting for
// review", which tells a reviewer nothing.
//
// changesRequested dominates because it is a person's decision: approving over
// the top of one overrides a colleague, not a build. Checks then outrank
// `approved`, as in Readiness — a red PR is waiting for a fix, not an approval.
// null checks means no CI at all, which must not look permanently unreviewable.
export function evaluateReviewState(request) {
  if (request.reviewDecision === "CHANGES_REQUESTED") return "changesRequested";
  if (request.checks === "FAILURE" || request.checks === "ERROR") return "checksFailing";
  if (request.checks === "PENDING" || request.checks === "EXPECTED") return "checksPending";
  if (request.viewerReviewDismissed) return "dismissed";
  return request.reviewDecision === "APPROVED" ? "approved" : "awaiting";
}

// `awaiting` is deliberately not "Waiting for review": that means somebody owes
// *you* a review; this means you owe *them* one.
export const REVIEW_LABELS = {
  changesRequested: "Changes requested",
  checksFailing: "Checks failing",
  checksPending: "Checks running",
  dismissed: "Approval dismissed",
  approved: "Approved already",
  awaiting: "Needs review",
};

// A full timestamp rather than a date: a date widens the window by up to 48
// hours depending on the hour it is built at. null (off) sends nothing.
export function createdQualifier(now, windowDays) {
  if (windowDays == null) return null;
  const cutoff = new Date(now.getTime() - windowDays * DAY_MS);
  return `created:>${cutoff.toISOString().replace(/\.\d+Z$/, "Z")}`;
}

// Strictly inside, matching `created:>` exactly, so the search and this filter
// cannot disagree. A future-dated PR (clock trailing GitHub's) counts as recent.
export function includesCreated(createdAt, now, windowDays) {
  if (windowDays == null) return false;
  return now - new Date(createdAt) < windowDays * DAY_MS;
}

// ---- Teams ----------------------------------------------------------------

// Both roles: `role` is viewer-relative and a team the user maintains is ADMIN,
// so asking for MEMBER alone silently drops every team they maintain.
// combinedSlug is `Org/team-slug`, exactly the form the search qualifier takes.
export const MY_TEAMS = `
query {
  viewer {
    organizations(first: 50) {
      nodes {
        login
        member: teams(first: 100, role: MEMBER) { nodes { name combinedSlug } }
        admin: teams(first: 100, role: ADMIN) { nodes { name combinedSlug } }
      }
    }
  }
}`;

// Errors first: a missing read:org scope or an SSO refusal arrives as a 200 with
// a null payload, and reading that as an empty list would tell the user they
// belong to no teams, leaving no reason to go and fix the scope.
export function decodeTeams(body) {
  assertNoErrors(body);
  const teams = body.data.viewer.organizations.nodes
    .filter(Boolean)
    .flatMap((org) => [...org.member.nodes, ...org.admin.nodes]);
  const seen = new Set();
  return teams
    .filter((t) => !seen.has(t.combinedSlug) && seen.add(t.combinedSlug))
    .sort((a, b) => a.combinedSlug.localeCompare(b.combinedSlug, undefined, { sensitivity: "base" }));
}

// ---- The search -----------------------------------------------------------

const REVIEW_FIELDS = `... on PullRequest {
      id number title url headRefOid createdAt updatedAt
      additions deletions changedFiles reviewDecision
      author { login }
      repository { nameWithOwner isPrivate }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }`;

// The team's own request is gone by the time a review is dismissed, so the
// timeline is the only record left of who was asked.
const DISMISSAL_FIELDS = `... on PullRequest {
      viewerLatestReview { state }
      timelineItems(first: 50, itemTypes: [REVIEW_REQUESTED_EVENT]) {
        nodes { ... on ReviewRequestedEvent { requestedReviewer { ... on Team { combinedSlug } } } }
      }
    }`;

// One aliased search per team in one document, so each team has its own cap
// (one team with 852 pending must not crowd out another with 8) and the alias
// says which team answered. A switched-off team is still asked, at first: 0:
// GitHub answers issueCount whatever the page size, which is what lets a settings
// list show what enabling it would cost. null when there is nothing to ask.
export function reviewRequestsQuery({ teams, disabled, windowDays, now }) {
  const created = createdQualifier(now, windowDays);
  if (teams.length === 0 || !created) return null;

  const declarations = [];
  const fields = [];
  const variables = {};
  teams.forEach((team, i) => {
    declarations.push(`$q${i}: String!, $n${i}: Int!`);
    fields.push(`  s${i}: search(query: $q${i}, type: ISSUE, first: $n${i}) {
    issueCount
    nodes { ${REVIEW_FIELDS} }
  }`);
    // -author:@me because nobody can approve their own PR (and those are listed
    // above); -reviewed-by:@me drops what the user has already dealt with.
    variables[`q${i}`] = `is:pr is:open archived:false draft:false team-review-requested:${team.combinedSlug} -author:@me -reviewed-by:@me ${created} sort:updated-desc`;
    variables[`n${i}`] = disabled.has(team.combinedSlug) ? 0 : PAGE_SIZE;
  });

  declarations.push(`$q${DISMISSAL}: String!, $n${DISMISSAL}: Int!`);
  fields.push(`  ${DISMISSAL}: search(query: $q${DISMISSAL}, type: ISSUE, first: $n${DISMISSAL}) {
    issueCount
    nodes { ${REVIEW_FIELDS} ${DISMISSAL_FIELDS} }
  }`);
  variables[`q${DISMISSAL}`] = `is:pr is:open archived:false draft:false -author:@me reviewed-by:@me review:none ${created} sort:updated-desc`;
  variables[`n${DISMISSAL}`] = teams.some((t) => !disabled.has(t.combinedSlug)) ? PAGE_SIZE : 0;

  return { query: document(declarations, fields), variables };
}

function toRequest(node, teams, viewerReviewDismissed) {
  return {
    id: node.id,
    number: node.number,
    title: node.title,
    url: node.url,
    repo: node.repository.nameWithOwner,
    isPrivate: node.repository.isPrivate,
    // GitHub reassigns a deleted account's PRs to `ghost`, so a deleted author must not lose the row.
    author: node.author?.login ?? "ghost",
    headRefOid: node.headRefOid,
    checks: node.commits.nodes[0]?.commit.statusCheckRollup?.state ?? null,
    reviewDecision: node.reviewDecision,
    createdAt: node.createdAt,
    updatedAt: node.updatedAt,
    additions: node.additions,
    deletions: node.deletions,
    changedFiles: node.changedFiles,
    teams,
    viewerReviewDismissed,
  };
}

// Deduplicated by PR id, carrying every team asked (a PR requested of two of
// your teams comes back under two aliases), teams in the caller's order, newest
// activity first. A team GitHub did not answer for is absent from the counts,
// not zero: zero would claim nothing is waiting.
export function decodeReviewRequests(body, teams) {
  assertNoErrors(body);
  const pendingCounts = {};
  const rows = new Map(); // insertion-ordered: the first sighting wins the fields

  teams.forEach((team, i) => {
    const search = body.data[`s${i}`];
    if (!search) return;
    pendingCounts[team.combinedSlug] = search.issueCount;
    for (const node of search.nodes) {
      const row = rows.get(node.id);
      if (row) row.teams.push(team);
      else rows.set(node.id, { node, teams: [team], dismissed: false });
    }
  });

  for (const node of body.data[DISMISSAL]?.nodes ?? []) {
    if (node.viewerLatestReview?.state !== "DISMISSED") continue;
    const asked = new Set((node.timelineItems?.nodes ?? []).map((e) => e.requestedReviewer?.combinedSlug).filter(Boolean));
    const askedTeams = teams.filter((t) => asked.has(t.combinedSlug));
    if (askedTeams.length === 0) continue;
    const row = rows.get(node.id);
    if (row) row.dismissed = true;
    else rows.set(node.id, { node, teams: askedTeams, dismissed: true });
  }

  const requests = [...rows.values()]
    .map(({ node, teams: t, dismissed }) => toRequest(node, t, dismissed))
    .sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
  return { requests, pendingCounts };
}

// ---- Display --------------------------------------------------------------

// The stale marker only appears at weeks, so "0 days" never mattered there; most
// of this section was opened this week, and "0 days" reads like a placeholder.
const recentAge = (createdAt, now) => (now - new Date(createdAt) < DAY_MS ? "today" : ageLabel(createdAt, now));

const plural = (n, noun) => (n === 1 ? `1 ${noun}` : `${n} ${noun}s`);

export function reviewRows(requests, now = new Date()) {
  return requests
    .filter((r) => r.url.startsWith("https://")) // links come from the network
    .map((r) => {
      const state = evaluateReviewState(r);
      return {
        id: r.id,
        number: r.number,
        title: r.title,
        repo: r.repo,
        author: r.author,
        state,
        status: REVIEW_LABELS[state],
        teams: r.teams.map((t) => t.combinedSlug).join(", "),
        size: `+${r.additions} −${r.deletions} · ${plural(r.changedFiles, "file")}`,
        age: recentAge(r.createdAt, now),
        url: r.url,
      };
    });
}

// ---- Network --------------------------------------------------------------

export async function fetchTeams({ token, fetchImpl = fetch }) {
  return decodeTeams(await post({ token, fetchImpl, query: MY_TEAMS }));
}

// Its own round trip, unlike the merged search that rides along with the open
// PRs, so one that cannot match is simply not sent.
//
// One request per search rather than the single combined document the macOS app
// sends: on a real account the searches took 2-8s each, and together they outran
// GitHub's time limit and came back as a 502. Run in parallel, so the section
// costs as long as its slowest search.
//
// DEFERRED (2026-10-30) — a switched-off team is not asked at all, so its pending
// count is absent; the macOS app asks it at first: 0 to show the count in
// settings. This port has no team settings yet.
export async function fetchReviewRequests({ token, fetchImpl = fetch, teams, disabled = new Set(), windowDays = 14, now = new Date() }) {
  const built = reviewRequestsQuery({ teams, disabled, windowDays, now });
  if (!built) return { requests: [], pendingCounts: {} };

  const { query, variables } = built;
  const all = [...teams.keys(), DISMISSAL];
  const enabled = all.filter((a) => variables[`n${a}`] > 0);
  const bodies = await Promise.all(
    enabled.map((only) => {
      const alone = { ...variables, ...Object.fromEntries(all.map((a) => [`n${a}`, a === only ? variables[`n${a}`] : 0])) };
      return post({ token, fetchImpl, query, variables: alone });
    }),
  );

  const data = {};
  enabled.forEach((a, i) => {
    assertNoErrors(bodies[i]);
    const key = a === DISMISSAL ? DISMISSAL : `s${a}`;
    data[key] = bodies[i].data[key];
  });
  return decodeReviewRequests({ data }, teams);
}
