// Loading one pull request's diff, pinned to the commits it was read at. Port of
// DiffClient.swift, DiffDecoder.swift and the live-state part of DiffStore.swift.
import { assertNoErrors, get, ownerOf, nameOf, post, query } from "./graphql.js";
import { parseHunks } from "./patch.js";

const COMPARE_FILE_LIMIT = 300; // the compare endpoint lists at most this many
const PULL_FILE_LIMIT = 3000; // GitHub lists at most this many; the rest cannot be shown
const FILES_PER_PAGE = 100;

const STATUSES = new Set(["added", "removed", "modified", "renamed", "copied", "changed", "unchanged"]);

// Both REST file lists (compare and pull files) use the same file object.
function content(file) {
  if (typeof file.patch !== "string") {
    return { kind: "omitted", reason: file.changes > 0 ? "tooLarge" : "noTextChanges" };
  }
  try {
    return { kind: "hunks", hunks: parseHunks(file.patch) };
  } catch {
    return { kind: "omitted", reason: "unparseable" };
  }
}

// Tolerant of a status GitHub adds later: it must not cost the reader the whole diff.
export function decodeFiles(restFiles) {
  return restFiles.map((f) => ({
    path: f.filename,
    previousPath: f.previous_filename ?? null,
    change: STATUSES.has(f.status) ? f.status : "modified",
    additions: f.additions,
    deletions: f.deletions,
    content: content(f),
    viewed: "UNVIEWED",
  }));
}

// Everything the diff is pinned to, plus one page of viewed states.
// `changedFiles` rather than `files.totalCount`: `files` is nullable.
const DIFF_META = `
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id baseRefOid headRefOid changedFiles bodyHTML
      files(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { path viewerViewedState }
      }
    }
  }
}`;

const DIFF_HEAD = `
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) { headRefOid }
  }
}`;

// Pinned by OID, which resolves on the base repository even for a fork's head.
const DIFF_ATTRIBUTES = `
query($owner: String!, $name: String!, $oid: GitObjectID!) {
  repository(owner: $owner, name: $name) {
    object(oid: $oid) {
      ... on Commit { file(path: ".gitattributes") { object { ... on Blob { text } } } }
    }
  }
}`;

const MARK_VIEWED = `
mutation($id: ID!, $path: String!) {
  markFileAsViewed(input: { pullRequestId: $id, path: $path }) { clientMutationId }
}`;

const UNMARK_VIEWED = `
mutation($id: ID!, $path: String!) {
  unmarkFileAsViewed(input: { pullRequestId: $id, path: $path }) { clientMutationId }
}`;

function pullRequestOf(body) {
  assertNoErrors(body);
  const pull = body.data.repository?.pullRequest;
  if (!pull) throw new Error("pull request not found");
  return pull;
}

export function decodeMeta(body) {
  const pull = pullRequestOf(body);
  const nodes = pull.files?.nodes ?? [];
  return {
    id: pull.id,
    baseOid: pull.baseRefOid,
    headOid: pull.headRefOid,
    changedFiles: pull.changedFiles,
    descriptionHTML: pull.bodyHTML ? pull.bodyHTML : null,
    viewed: new Map(nodes.map((n) => [n.path, n.viewerViewedState])),
    nextCursor: pull.files?.pageInfo.hasNextPage ? pull.files.pageInfo.endCursor : null,
  };
}

class HeadMoved extends Error {
  constructor() {
    super("the pull request head moved while the diff was loading");
  }
}

const variablesFor = (repo, number) => ({ owner: ownerOf(repo), name: nameOf(repo), number });

async function readMeta(args, repo, number) {
  let meta = null;
  let after = null;
  do {
    const variables = { ...variablesFor(repo, number), ...(after ? { after } : {}) };
    const page = decodeMeta(await post({ ...args, query: DIFF_META, variables }));
    if (meta) for (const [path, state] of page.viewed) meta.viewed.set(path, state);
    else meta = page;
    after = page.nextCursor;
  } while (after && meta.viewed.size < PULL_FILE_LIMIT);
  return meta;
}

async function pagedFiles(args, repo, number) {
  const files = [];
  for (let page = 1; page <= PULL_FILE_LIMIT / FILES_PER_PAGE; page++) {
    const url = `https://api.github.com/repos/${repo}/pulls/${number}/files?per_page=${FILES_PER_PAGE}&page=${page}`;
    const batch = await get({ ...args, url });
    files.push(...batch);
    if (batch.length < FILES_PER_PAGE) break;
  }
  return files;
}

async function currentHead(args, repo, number) {
  return pullRequestOf(await post({ ...args, query: DIFF_HEAD, variables: variablesFor(repo, number) })).headRefOid;
}

async function readDiff(args, repo, number) {
  const meta = await readMeta(args, repo, number);
  let restFiles;
  if (meta.changedFiles <= COMPARE_FILE_LIMIT) {
    // Pinned by SHA, so a push after the metadata read cannot change it.
    restFiles = (await get({ ...args, url: `https://api.github.com/repos/${repo}/compare/${meta.baseOid}...${meta.headOid}` })).files;
  } else {
    restFiles = await pagedFiles(args, repo, number);
    // The paged listing is not pinned to a SHA, so it is only trusted if the head did not move.
    if ((await currentHead(args, repo, number)) !== meta.headOid) throw new HeadMoved();
  }
  const files = decodeFiles(restFiles).map((f) => ({ ...f, viewed: meta.viewed.get(f.path) ?? "UNVIEWED" }));
  return {
    pullRequestID: meta.id,
    baseOid: meta.baseOid,
    headOid: meta.headOid, // what Merge and Approve are pinned to
    files,
    isTruncated: meta.changedFiles > PULL_FILE_LIMIT,
    gitAttributes: null,
    descriptionHTML: meta.descriptionHTML,
  };
}

export async function loadDiff({ token, fetchImpl = fetch, repo, number }) {
  const args = { token, fetchImpl };
  let diff;
  try {
    diff = await readDiff(args, repo, number);
  } catch (e) {
    if (!(e instanceof HeadMoved)) throw e;
    diff = await readDiff(args, repo, number); // once; a second move is a real push storm
  }
  // Only sorts files into sections, so losing it must not cost the diff.
  try {
    const data = await query({ ...args, query: DIFF_ATTRIBUTES, variables: { owner: ownerOf(repo), name: nameOf(repo), oid: diff.headOid } });
    diff.gitAttributes = data.repository?.object?.file?.object?.text ?? null;
  } catch {
    diff.gitAttributes = null;
  }
  return diff;
}

export async function setViewed({ token, fetchImpl = fetch, pullRequestID, path, viewed }) {
  const data = await query({ token, fetchImpl, query: viewed ? MARK_VIEWED : UNMARK_VIEWED, variables: { id: pullRequestID, path } });
  if (!Object.values(data).some((v) => v !== null)) throw new Error("GitHub did not confirm the file's viewed state.");
}

// ---- Merge and approve act on exactly what was read -------------------------

// The live row says whether the PR is still open and where its head is now; the
// diff never re-derives that from itself. null: gone (merged or closed
// elsewhere). undefined: not heard from yet, so nothing contradicts what was read.
export function observeLive(diff, liveHead) {
  if (liveHead === undefined) return "loaded";
  if (liveHead === null) return "closed";
  return liveHead === diff.headOid ? "loaded" : "headMoved";
}

// Non-null only while what was read is still what GitHub would act on. A
// truncated diff never qualifies: part of it was never shown.
export function mergeTarget({ phase, isReady, diff }) {
  if (phase !== "loaded" || !isReady || !diff || diff.isTruncated) return null;
  return { id: diff.pullRequestID, oid: diff.headOid };
}
