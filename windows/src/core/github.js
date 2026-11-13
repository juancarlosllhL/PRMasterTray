import { mergeReleases, refreshDeployments } from "./deployments.js";
import { assertNoErrors, post } from "./graphql.js";
import { evaluate } from "./readiness.js";
import { candidates, containmentKey, isRecent, mergedQualifier, releaseDepth, resolve } from "./shipment.js";

// Same open-PR half as Sources/PRMasterCore/Queries.swift `myPullRequests`.
const OPEN_PULL_REQUESTS = `
query {
  open: search(
    query: "is:pr is:open author:@me archived:false sort:updated-desc"
    type: ISSUE
    first: 50
  ) {
    nodes {
      ... on PullRequest {
        id number title url isDraft headRefOid updatedAt createdAt
        mergeable mergeStateStatus reviewDecision
        repository { nameWithOwner isPrivate }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        reviews(states: APPROVED) { totalCount }
      }
    }
  }
}`;

const REVIEW_THREADS = `
query($ids: [ID!]!) {
  nodes(ids: $ids) {
    ... on PullRequest {
      id
      reviewThreads(first: 100) {
        nodes { isResolved comments(first: 1) { nodes { author { login } } } }
      }
    }
  }
}`;

const QUILL_LOGIN = "quill-reviewer";

export function decodeOpenPullRequests(body) {
  assertNoErrors(body);
  return body.data.open.nodes
    .filter((n) => n.id) // search can return issues; the fragment leaves them empty
    .map((n) => {
      const pr = {
        id: n.id,
        number: n.number,
        title: n.title,
        url: n.url,
        repo: n.repository.nameWithOwner,
        isPrivate: n.repository.isPrivate,
        isDraft: n.isDraft,
        headRefOid: n.headRefOid,
        mergeable: n.mergeable,
        mergeState: n.mergeStateStatus,
        reviewDecision: n.reviewDecision,
        checks: n.commits.nodes[0]?.commit.statusCheckRollup?.state ?? null,
        approvals: n.reviews.totalCount,
        updatedAt: n.updatedAt,
        createdAt: n.createdAt,
        threads: null,
      };
      return { ...pr, readiness: evaluate(pr) };
    });
}

export function decodeReviewThreads(body) {
  assertNoErrors(body);
  const tallies = new Map();
  for (const n of body.data.nodes) {
    if (!n?.id) continue;
    const open = n.reviewThreads.nodes.filter((t) => !t.isResolved);
    tallies.set(n.id, {
      unresolved: open.length,
      unresolvedByQuill: open.filter((t) => t.comments.nodes[0]?.author?.login === QUILL_LOGIN).length,
    });
  }
  return tallies;
}

export async function fetchMyPullRequests({ token, fetchImpl = fetch }) {
  const open = decodeOpenPullRequests(await post({ token, fetchImpl, query: OPEN_PULL_REQUESTS }));
  const blockedIds = open.filter((p) => p.readiness === "blocked").map((p) => p.id);
  if (blockedIds.length === 0) return open;

  // Losing the threads must not cost the list; those rows stay "Waiting for review".
  try {
    const body = await post({ token, fetchImpl, query: REVIEW_THREADS, variables: { ids: blockedIds } });
    const tallies = decodeReviewThreads(body);
    return open.map((p) => {
      if (!tallies.has(p.id)) return p;
      const withThreads = { ...p, threads: tallies.get(p.id) };
      return { ...withThreads, readiness: evaluate(withThreads) };
    });
  } catch {
    return open;
  }
}

const SQUASH_MERGE = `
mutation($id: ID!, $oid: GitObjectID!) {
  mergePullRequest(input: { pullRequestId: $id, expectedHeadOid: $oid, mergeMethod: SQUASH }) {
    pullRequest { merged }
  }
}`;

// updateMethod is deliberately absent: GitHub's default (MERGE) is what its own
// "Update branch" button does. REBASE would force-push the user's branch.
const UPDATE_BRANCH = `
mutation($id: ID!, $oid: GitObjectID!) {
  updatePullRequestBranch(input: { pullRequestId: $id, expectedHeadOid: $oid }) {
    pullRequest { id headRefOid }
  }
}`;

// ClosePullRequestInput takes no expectedHeadOid, so nothing here refuses a
// stale row: the confirmation in front of it is the whole protection.
const CLOSE_PULL_REQUEST = `
mutation($id: ID!) {
  closePullRequest(input: { pullRequestId: $id }) {
    pullRequest { id state }
  }
}`;

async function mutate({ token, fetchImpl = fetch, query, variables }) {
  const body = await post({ token, fetchImpl, query, variables });
  assertNoErrors(body);
  return body.data;
}

// GitHub can answer a refused merge with a well-formed 200, so the returned
// state is the only trustworthy confirmation.
export async function squashMerge({ token, fetchImpl, id, expectedHeadOid }) {
  const data = await mutate({ token, fetchImpl, query: SQUASH_MERGE, variables: { id, oid: expectedHeadOid } });
  if (!data.mergePullRequest?.pullRequest?.merged) throw new Error("GitHub reports the pull request was not merged");
}

export async function updateBranch({ token, fetchImpl, id, expectedHeadOid }) {
  await mutate({ token, fetchImpl, query: UPDATE_BRANCH, variables: { id, oid: expectedHeadOid } });
}

export async function closePullRequest({ token, fetchImpl, id }) {
  const data = await mutate({ token, fetchImpl, query: CLOSE_PULL_REQUEST, variables: { id } });
  if (data.closePullRequest?.pullRequest?.state !== "CLOSED") throw new Error("The pull request was not closed");
}

// ---- Recently merged ------------------------------------------------------

const MERGED_PULL_REQUESTS = `
query($mergedQuery: String!) {
  merged: search(query: $mergedQuery, type: ISSUE, first: 30) {
    nodes {
      ... on PullRequest {
        id number title url mergedAt
        repository { id nameWithOwner isPrivate }
        mergeCommit {
          oid
          statusCheckRollup {
            state
            contexts(first: 30) {
              nodes {
                __typename
                ... on StatusContext { context state targetUrl }
                ... on CheckRun { name status conclusion detailsUrl }
              }
            }
          }
        }
      }
    }
  }
}`;

// Keyed by node ID: the merged search already returns repository ids, so no
// remote string has to be interpolated anywhere.
const RELEASES = `
query($repoIds: [ID!]!, $first: Int!) {
  nodes(ids: $repoIds) {
    ... on Repository {
      id
      releases(first: $first, orderBy: {field: CREATED_AT, direction: DESC}) {
        nodes { tagName url createdAt publishedAt isDraft tagCommit { oid } }
      }
    }
  }
}`;

const FAILING_CONCLUSIONS = new Set(["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "CANCELLED", "STALE"]);
const PASSING_CONCLUSIONS = new Set(["SUCCESS", "NEUTRAL", "SKIPPED"]);

// A run that has not completed is pending whatever its conclusion says.
// cancelled and stale count as failures: both are terminal, and "building" for
// something that stopped an hour ago is the one answer that is never true.
// A conclusion GitHub adds later reads as "no usable answer", never a good one.
function runState({ status, conclusion }) {
  if (status !== "COMPLETED") return "PENDING";
  if (PASSING_CONCLUSIONS.has(conclusion)) return "SUCCESS";
  if (FAILING_CONCLUSIONS.has(conclusion)) return "FAILURE";
  return "PENDING";
}

// GitHub reports checks as a CheckRun/StatusContext union with different field
// names for the same idea; collapse them once so nothing downstream cares.
function decodeContext(node) {
  if (node.__typename === "CheckRun") {
    return { name: node.name, state: runState(node), url: node.detailsUrl ?? null, isWorkflow: true };
  }
  if (node.__typename === "StatusContext") {
    return { name: node.context, state: node.state, url: node.targetUrl ?? null, isWorkflow: false };
  }
  return null;
}

export function decodeMerged(body) {
  assertNoErrors(body);
  return body.data.merged.nodes
    .filter((n) => n.id)
    .map((n) => ({
      id: n.id,
      number: n.number,
      title: n.title,
      url: n.url,
      repo: n.repository.nameWithOwner,
      repositoryID: n.repository.id,
      isPrivate: n.repository.isPrivate,
      mergedAt: n.mergedAt,
      mergeCommitOid: n.mergeCommit?.oid ?? null,
      rollupState: n.mergeCommit?.statusCheckRollup?.state ?? null,
      contexts: (n.mergeCommit?.statusCheckRollup?.contexts.nodes ?? []).map(decodeContext).filter(Boolean),
    }));
}

// Drafts are excluded: nothing runs a release that was never published. A tag
// that points at something other than a commit cannot be compared.
export function decodeReleases(body) {
  assertNoErrors(body);
  const out = {};
  for (const node of body.data.nodes) {
    if (!node?.id) continue; // a repository deleted or renamed mid-flight
    out[node.id] = node.releases.nodes
      .filter((r) => !r.isDraft && r.tagCommit)
      .map((r) => ({ tagName: r.tagName, url: r.url, tagCommitOid: r.tagCommit.oid, createdAt: r.createdAt, publishedAt: r.publishedAt }));
  }
  return out;
}

// The only query assembled from data GitHub sent us, so aliases and variable
// *names* are generated and every remote *value* rides as a variable: nothing
// untrusted reaches the document. (A tag like `v3.31.2` is not a legal alias.)
export function containmentQuery(cands) {
  if (cands.length === 0) return null;
  const declarations = [];
  const fields = [];
  const variables = {};
  cands.forEach(({ pr, release }, i) => {
    declarations.push(`$owner${i}: String!, $name${i}: String!, $tag${i}: String!, $oid${i}: String!`);
    fields.push(`  t${i}: repository(owner: $owner${i}, name: $name${i}) {
    ref(qualifiedName: $tag${i}) { compare(headRef: $oid${i}) { status } }
  }`);
    const slash = pr.repo.indexOf("/");
    variables[`owner${i}`] = pr.repo.slice(0, slash);
    variables[`name${i}`] = pr.repo.slice(slash + 1);
    variables[`tag${i}`] = `refs/tags/${release.tagName}`;
    variables[`oid${i}`] = pr.mergeCommitOid;
  });
  return { query: `query(${declarations.join(", ")}) {\n${fields.join("\n")}\n}`, variables };
}

const CONTAINS = { BEHIND: true, IDENTICAL: true, AHEAD: false, DIVERGED: false };

// A candidate with no answer is omitted rather than recorded as false: unknown
// and no are different, and only one of them is safe to act on.
export function decodeContainment(body, cands) {
  assertNoErrors(body);
  const out = new Map();
  cands.forEach(({ pr, release }, i) => {
    const contains = CONTAINS[body.data[`t${i}`]?.ref?.compare?.status];
    if (contains !== undefined) out.set(containmentKey(pr.id, release.tagName), contains);
  });
  return out;
}

// `deployments` (see newDeploymentsState) is carried across polls by the caller;
// without it rows carry no stg/prod chips.
export async function fetchShipments({ token, fetchImpl = fetch, now = new Date(), windowDays = 1, deployments }) {
  if (windowDays == null) return []; // switched off: there is nothing to ask for
  const mergedQuery = `is:pr is:merged author:@me archived:false ${mergedQualifier(now, windowDays)} sort:updated-desc`;
  const merged = decodeMerged(await post({ token, fetchImpl, query: MERGED_PULL_REQUESTS, variables: { mergedQuery } }))
    .filter((m) => isRecent(m.mergedAt, now, windowDays));
  if (merged.length === 0) return []; // most of the day: don't spend rate-limit points on nothing

  // Losing release information must not cost the list: rows fall back to checks only.
  let releases = {};
  try {
    const repoIds = [...new Set(merged.map((m) => m.repositoryID))];
    releases = decodeReleases(await post({ token, fetchImpl, query: RELEASES, variables: { repoIds, first: releaseDepth(windowDays) } }));
  } catch {
    // Keep whatever was resolved.
  }
  if (deployments) await refreshDeployments({ token, fetchImpl, state: deployments, merged, releases });

  // Containment is asked over every release in hand, including the ones the
  // environments' versions led us to.
  const effective = deployments ? mergeReleases(releases, deployments.promotedReleases) : releases;
  let containment = new Map();
  try {
    const cands = candidates(merged, effective);
    const built = containmentQuery(cands);
    if (built) containment = decodeContainment(await post({ token, fetchImpl, query: built.query, variables: built.variables }), cands);
  } catch {
    // Unknown, never "not contained".
  }
  return resolve({ merged, releases: effective, containment, promotions: deployments?.promotions });
}

// Approving is the one write aimed at somebody else's pull request. `commitOID`
// is a record of the commit the reviewer read, not a guard: GitHub pins the
// review to it rather than refusing a head that has moved, so the window's
// confirmation (and its head-moved check) is what actually protects this.
// `body` is omitted rather than sent as null.
const APPROVE_PULL_REQUEST = `
mutation($id: ID!, $oid: GitObjectID!, $body: String) {
  addPullRequestReview(input: { pullRequestId: $id, commitOID: $oid, event: APPROVE, body: $body }) {
    pullRequestReview { state }
  }
}`;

// The returned state is the only trustworthy confirmation: GitHub answers a
// review it declined to record as an approval with a perfectly well-formed 200.
export async function approvePullRequest({ token, fetchImpl, id, commitOID, body }) {
  const variables = { id, oid: commitOID, ...(body === undefined ? {} : { body }) };
  const data = await mutate({ token, fetchImpl, query: APPROVE_PULL_REQUEST, variables });
  if (data.addPullRequestReview?.pullRequestReview?.state !== "APPROVED") throw new Error("The approval was not recorded");
}
