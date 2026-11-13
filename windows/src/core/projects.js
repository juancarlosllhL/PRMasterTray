// GitHub Projects boards and the pull requests carrying a Jira key. Port of
// GitHubProject.swift, ProjectItem.swift, ProjectLaneMap.swift,
// ProjectDecoding.swift and the project / issue-link parts of Queries.swift and
// GitHubClient.swift.
import { assertNoErrors, document, post } from "./graphql.js";
import { BOARD_LANES, guessLane } from "./jira.js";

export class ProjectScopeError extends Error {
  constructor() {
    super("Reading projects needs the read:project scope (and moving cards needs project). Run `gh auth refresh -s project` once; if your shell sets GH_TOKEN, refresh the stored token instead: `env -u GH_TOKEN gh auth refresh -h github.com -s project`.");
    this.name = "ProjectScopeError";
  }
}

// ---- Which column a Status option lands in ----------------------------------

// Stands in for an option id on items with no Status at all, which are not yet triaged and start hidden.
const NO_STATUS = "";

// Where each project's Status options land on the board. Only the user's own
// choices are stored; everything else is guessed from the option's name. Keyed by
// option id, so renaming a column on GitHub keeps its choice. A choice is a lane id, or "hidden".
export class LaneMap {
  constructor(overrides = {}) {
    this.overrides = overrides;
  }

  choice(optionID, name, project) {
    const chosen = this.overrides[project]?.[optionID ?? NO_STATUS];
    if (chosen) return chosen;
    if (optionID == null) return "hidden";
    return guessLane(name ?? "") ?? "hidden";
  }

  lane(optionID, name, project) {
    const choice = this.choice(optionID, name, project);
    return choice === "hidden" ? null : choice;
  }

  set(choice, optionID, project) {
    (this.overrides[project] ??= {})[optionID] = choice;
  }

  // The option a move into `lane` sets: the one named like the column, or else
  // the first that lands there in board order. null says there is none.
  target(lane, project) {
    const landing = project.options.filter((o) => this.lane(o.id, o.name, project.id) === lane);
    const title = BOARD_LANES.find((l) => l.id === lane).title.toLowerCase();
    return landing.find((o) => o.name.toLowerCase() === title) ?? landing[0] ?? null;
  }

  toJSON() {
    return this.overrides;
  }
}

// ---- Decoding ---------------------------------------------------------------

// Errors first: GitHub reports a missing scope as a 200 with a null payload.
function envelope(body) {
  if (body.errors?.some((e) => e.type === "INSUFFICIENT_SCOPES" && e.message.includes("project'"))) throw new ProjectScopeError();
  assertNoErrors(body);
  if (!body.data) throw new Error("response contained neither data nor errors");
  return body.data;
}

const decodeProject = (n) => ({
  id: n.id,
  number: n.number,
  title: n.title,
  owner: n.owner?.login ?? "",
  url: n.url,
  statusFieldID: n.field?.id ?? null,
  options: n.field?.id ? (n.field.options ?? []).map((o) => ({ id: o.id, name: o.name })) : [],
});

// Every open project found by any route, once each, sorted by title.
export function decodeProjects(body) {
  const { viewer } = envelope(body);
  const orgs = (viewer.organizations.nodes ?? []).filter(Boolean);
  const found = [
    ...(viewer.projectsV2.nodes ?? []),
    ...orgs.flatMap((o) => [...(o.recentProjects?.nodes ?? []), ...(o.projects?.nodes ?? [])]),
  ].filter(Boolean);
  const seen = new Set();
  return found
    .filter((n) => !n.closed && !seen.has(n.id) && seen.add(n.id))
    .map(decodeProject)
    .sort((a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: "base" }));
}

export const decodeLogin = (body) => envelope(body).viewer.login;

// A pull request or issue on a board. The same issue on two boards is two items,
// each with its own Status; the id is the item's node id, which a move names.
class ProjectItem {
  constructor(fields) {
    Object.assign(this, fields);
  }

  // The repository's name without its owner, as GitHub writes a reference.
  get reference() {
    return `${this.repo.split("/").pop()}#${this.number}`;
  }
}

const decodeLink = (n) => ({
  id: n.id,
  number: n.number,
  title: n.title,
  url: n.url,
  repo: n.repository.nameWithOwner,
  isPrivate: n.repository.isPrivate,
  isDraft: n.isDraft,
  // The fallback is open, never merged: an unrecognised state must not say work has shipped.
  state: ["OPEN", "MERGED", "CLOSED"].includes(n.state) ? n.state : "OPEN",
});

function decodeItem(node, projectID) {
  const c = node?.content;
  // Drafts have no repository or URL, and a redacted item has no content at all.
  if (!c || (c.__typename !== "Issue" && c.__typename !== "PullRequest")) return null;
  if (c.number == null || !c.title || !c.url || !c.repository?.nameWithOwner) return null;
  const isPullRequest = c.__typename === "PullRequest";
  return new ProjectItem({
    id: node.id,
    projectID,
    number: c.number,
    title: c.title,
    url: c.url,
    repo: c.repository.nameWithOwner,
    isPullRequest,
    typeName: c.issueType?.name ?? (isPullRequest ? "Pull request" : "Issue"),
    statusOptionID: node.status?.optionId ?? null,
    statusName: node.status?.name ?? null,
    statusChangedAt: node.status?.updatedAt ?? null,
    createdAt: c.createdAt ?? null,
    links: (c.closedByPullRequestsReferences?.nodes ?? []).filter(Boolean).map(decodeLink),
  });
}

export function decodeItems(body, projectID) {
  const items = envelope(body).node?.items;
  if (!items) throw new Error(`project ${projectID} answered with no items`);
  return {
    items: (items.nodes ?? []).map((n) => decodeItem(n, projectID)).filter(Boolean),
    next: items.pageInfo.hasNextPage ? items.pageInfo.endCursor : null,
  };
}

export function decodeStatusUpdate(body) {
  if (!envelope(body).updateProjectV2ItemFieldValue?.projectV2Item?.id) throw new Error("GitHub never confirmed the move");
}

// ---- Queries ----------------------------------------------------------------

// Your own boards, and each organization's most recently updated ones plus any you
// changed lately. Team projects were measured finding none of the boards in use,
// and recent projects alone missed two. Needs `read:project`.
const MY_PROJECTS = `
query {
  viewer {
    projectsV2(first: 20) { nodes { ...ProjectFields } }
    organizations(first: 20) {
      nodes {
        recentProjects(first: 20) { nodes { ...ProjectFields } }
        projects: projectsV2(first: 20, orderBy: { field: UPDATED_AT, direction: DESC }) { nodes { ...ProjectFields } }
      }
    }
  }
}
fragment ProjectFields on ProjectV2 {
  id number title url closed
  owner { ... on Organization { login } ... on User { login } }
  field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } }
}`;

const VIEWER_LOGIN = "query { viewer { login } }";
const ITEM_PAGE_CAP = 5;

// `$q` names the viewer's login rather than `@me`: the login was measured filtering
// on GitHub's side, `@me` could not be. Archived items are left out by GitHub's default.
const PROJECT_ITEMS = `
query($id: ID!, $after: String, $q: String!) {
  node(id: $id) {
    ... on ProjectV2 {
      items(first: 100, after: $after, query: $q) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          status: fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { optionId name updatedAt }
          }
          content {
            __typename
            ... on Issue {
              number title url createdAt
              issueType { name }
              repository { nameWithOwner }
              closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
                nodes { id number title url state isDraft repository { nameWithOwner isPrivate } }
              }
            }
            ... on PullRequest {
              number title url createdAt
              repository { nameWithOwner }
            }
          }
        }
      }
    }
  }
}`;

const SET_STATUS = `
mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
  updateProjectV2ItemFieldValue(input: { projectId: $project, itemId: $item, fieldId: $field, value: { singleSelectOptionId: $option } }) {
    projectV2Item { id }
  }
}`;

// `token` is a string, or a function returning one (so a retry can pick up a token
// `gh auth refresh -s project` has just handed out, which would otherwise wait for a relaunch).
const tokenOf = async (token) => (typeof token === "function" ? token() : token);

async function retryingScope(token, attempt) {
  try {
    return await attempt(await tokenOf(token));
  } catch (e) {
    if (!(e instanceof ProjectScopeError)) throw e;
    return attempt(await tokenOf(token));
  }
}

export const fetchProjects = ({ token, fetchImpl = fetch }) =>
  retryingScope(token, async (t) => decodeProjects(await post({ token: t, fetchImpl, query: MY_PROJECTS })));

export const fetchViewerLogin = async ({ token, fetchImpl = fetch }) => decodeLogin(await post({ token: await tokenOf(token), fetchImpl, query: VIEWER_LOGIN }));

// Stops after a few pages, so a runaway board cannot spin.
export async function fetchProjectItems({ token, fetchImpl = fetch, projectID, login }) {
  const who = login ?? (await fetchViewerLogin({ token, fetchImpl }));
  const items = [];
  let after = null;
  for (let page = 0; page < ITEM_PAGE_CAP; page++) {
    const variables = { id: projectID, q: `assignee:${who}`, ...(after ? { after } : {}) };
    const result = await retryingScope(token, async (t) => decodeItems(await post({ token: t, fetchImpl, query: PROJECT_ITEMS, variables }), projectID));
    items.push(...result.items);
    if (!result.next) break;
    after = result.next;
  }
  return items;
}

export const setProjectStatus = ({ token, fetchImpl = fetch, project, item, field, option }) =>
  retryingScope(token, async (t) => decodeStatusUpdate(await post({ token: t, fetchImpl, query: SET_STATUS, variables: { project, item, field, option } })));

// ---- Pull requests carrying a Jira key --------------------------------------

// One document of aliased searches costs a measured rate limit of 1 whatever the
// alias count. null past the cap, so an over-long document is refused rather than silently truncated.
export const ISSUE_KEY_ALIAS_CAP = 20;

export function issueLinksQuery(keys) {
  const unique = [...new Set(keys)];
  if (unique.length === 0 || unique.length > ISSUE_KEY_ALIAS_CAP) return null;
  const declarations = [];
  const fields = [];
  const variables = {};
  unique.forEach((key, i) => {
    declarations.push(`$q${i}: String!`);
    fields.push(`  k${i}: search(query: $q${i}, type: ISSUE, first: 20) {
    nodes {
      ... on PullRequest {
        id number title url state isDraft
        repository { nameWithOwner isPrivate }
      }
    }
  }`);
    variables[`q${i}`] = `${key} in:title is:pr author:@me`;
  });
  return { query: document(declarations, fields), variables };
}

// Empty rather than absent for a key with no hits: absent would read as "not
// looked up yet", which is not the same as "none exist".
export function decodeIssueLinks(body, keys) {
  assertNoErrors(body);
  return Object.fromEntries(keys.map((key, i) => [key, (body.data[`k${i}`]?.nodes ?? []).filter(Boolean).map(decodeLink)]));
}

export async function fetchPullRequestsForIssueKeys({ token, fetchImpl = fetch, keys }) {
  const built = issueLinksQuery(keys);
  if (!built) return {};
  return decodeIssueLinks(await post({ token: await tokenOf(token), fetchImpl, ...built }), [...new Set(keys)]);
}

// `owner/repo#123` rather than a bare number, which is ambiguous across repositories.
export const linkedPullRequestId = (repo, number) => `${repo}#${number}`;
