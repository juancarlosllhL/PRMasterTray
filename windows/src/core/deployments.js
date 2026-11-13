// Reading what each environment runs from the deployments repositories.
// Port of the deployment half of GitHubClient.swift and Queries.swift.
import { assertNoErrors, document, nameOf, ownerOf, post, query } from "./graphql.js";
import { unidentifiedVersions } from "./shipment.js";
import { declaresImage, imageNames, isKargoManaged, locationsFromSearchPaths, parsePromotionFile, stableVersion, stripVersion } from "./promotion.js";

const locationKey = (location) => `${location.deploymentsRepo}|${location.appPath}`;

const FILE_TEXT = `
query($owner: String!, $name: String!, $expression: String!) {
  repository(owner: $owner, name: $name) {
    object(expression: $expression) { ... on Blob { text } }
  }
}`;

// Addressed at HEAD rather than main: nothing guarantees every deployments
// repository names its default branch alike, and a wrong branch would read as an
// app nobody ever promoted to. The entry oids are what make blob reads skippable.
export function treesQuery(locations) {
  if (locations.length === 0) return null;
  const declarations = [];
  const fields = [];
  const variables = {};
  locations.forEach((location, i) => {
    declarations.push(`$owner${i}: String!, $name${i}: String!, $tree${i}: String!`);
    fields.push(`  t${i}: repository(owner: $owner${i}, name: $name${i}) {
    object(expression: $tree${i}) { ... on Tree { entries { name object { oid } } } }
  }`);
    variables[`owner${i}`] = ownerOf(location.deploymentsRepo);
    variables[`name${i}`] = nameOf(location.deploymentsRepo);
    variables[`tree${i}`] = `HEAD:${location.appPath}`;
  });
  return { query: document(declarations, fields), variables };
}

// A folder GitHub could not resolve is omitted rather than recorded as empty: an
// app whose tree failed to load has not been shown to have no promotions.
export function decodeTrees(body, locations) {
  assertNoErrors(body);
  const data = body.data;
  const out = new Map();
  locations.forEach((location, i) => {
    const entries = data[`t${i}`]?.object?.entries;
    if (!entries) return;
    out.set(locationKey(location), entries.filter((e) => e.object).map((e) => ({ name: e.name, oid: e.object.oid })));
  });
  return out;
}

export function blobsQuery(requests) {
  if (requests.length === 0) return null;
  const declarations = [];
  const fields = [];
  const variables = {};
  requests.forEach(({ location, file }, i) => {
    declarations.push(`$owner${i}: String!, $name${i}: String!, $blob${i}: String!`);
    fields.push(`  b${i}: repository(owner: $owner${i}, name: $name${i}) {
    object(expression: $blob${i}) { ... on Blob { text } }
  }`);
    variables[`owner${i}`] = ownerOf(location.deploymentsRepo);
    variables[`name${i}`] = nameOf(location.deploymentsRepo);
    variables[`blob${i}`] = `HEAD:${location.appPath}/${file}`;
  });
  return { query: document(declarations, fields), variables };
}

export function decodeBlobs(body, requests) {
  assertNoErrors(body);
  const data = body.data;
  const out = new Map();
  requests.forEach(({ oid }, i) => {
    const text = data[`b${i}`]?.object?.text;
    if (typeof text === "string") out.set(oid, text);
  });
  return out;
}

const RELEASE_FIELDS = "tagName url createdAt publishedAt isDraft tagCommit { oid }";

// A values file names `3.31.1` and the release is tagged `v3.31.1`, but nothing
// guarantees the prefix; GitHub answers a missing tag with null, not an error, so
// asking for both spellings costs one field rather than one request.
export function tagReleasesQuery(requests) {
  if (requests.length === 0) return null;
  const declarations = [];
  const fields = [];
  const variables = {};
  requests.forEach(({ repo, version }, i) => {
    declarations.push(`$owner${i}: String!, $name${i}: String!, $prefixed${i}: String!, $bare${i}: String!`);
    fields.push(`  r${i}: repository(owner: $owner${i}, name: $name${i}) {
    prefixed: release(tagName: $prefixed${i}) { ${RELEASE_FIELDS} }
    bare: release(tagName: $bare${i}) { ${RELEASE_FIELDS} }
  }`);
    variables[`owner${i}`] = ownerOf(repo);
    variables[`name${i}`] = nameOf(repo);
    variables[`prefixed${i}`] = `v${version}`;
    variables[`bare${i}`] = version;
  });
  return { query: document(declarations, fields), variables };
}

// Keyed by the repository node ID the caller asked under. Drafts are excluded:
// nothing runs a release that was never published.
export function decodeTagReleases(body, requests) {
  assertNoErrors(body);
  const data = body.data;
  const out = {};
  requests.forEach(({ repositoryID }, i) => {
    const release = data[`r${i}`]?.prefixed ?? data[`r${i}`]?.bare;
    if (!release || release.isDraft || !release.tagCommit) return;
    (out[repositoryID] ??= []).push({
      tagName: release.tagName,
      url: release.url,
      tagCommitOid: release.tagCommit.oid,
      createdAt: release.createdAt,
      publishedAt: release.publishedAt,
    });
  });
  return out;
}

async function fileText({ token, fetchImpl, repo, path }) {
  const data = await query({
    token,
    fetchImpl,
    query: FILE_TEXT,
    variables: { owner: ownerOf(repo), name: nameOf(repo), expression: `HEAD:${path}` },
  });
  return data.repository?.object?.text ?? null;
}

// REST rather than GraphQL: GitHub exposes code search only there.
async function searchCode({ token, fetchImpl, image, org }) {
  const url = new URL("https://api.github.com/search/code");
  url.searchParams.set("q", `"${image}" org:${org} filename:values.yaml`);
  url.searchParams.set("per_page", "50");
  const res = await fetchImpl(url.toString(), { headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json" } });
  if (!res.ok) throw new Error(`GitHub code search responded ${res.status}`);
  return (await res.json()).items.map((item) => ({ repo: item.repository.full_name, path: item.path }));
}

// The app folders a service repository ships into, joined on the image name.
// A repository with no CircleCI config or no image deploys nothing, which is not
// an error.
export async function discover({ token, fetchImpl = fetch, repo }) {
  const config = await fileText({ token, fetchImpl, repo, path: ".circleci/config.yml" });
  if (config === null) return [];

  const verified = [];
  for (const image of imageNames(config)) {
    for (const hit of await searchCode({ token, fetchImpl, image, org: ownerOf(repo) })) {
      // Rendered copies are dropped before being read: they would declare the
      // image just as truthfully and cost a request each.
      if (hit.path.startsWith(".stages/")) continue;
      // Search matches a substring; only a declaration counts. A file that
      // cannot be read is dropped rather than trusted.
      const text = await fileText({ token, fetchImpl, repo: hit.repo, path: hit.path });
      if (text !== null && declaresImage(image, text)) verified.push(hit);
    }
  }
  return locationsFromSearchPaths(verified);
}

// Every region's promoted version, per app folder (keyed "repo|appPath").
// `cache` maps blob oid -> version (or null for a file naming none): unchanged
// content means an unchanged version, so a steady-state poll is one tree listing.
export async function fetchPromotions({ token, fetchImpl = fetch, locations, cache }) {
  const treeQuery = treesQuery(locations);
  if (!treeQuery) return new Map();
  const trees = decodeTrees(await post({ token, fetchImpl, ...treeQuery }), locations);

  // Only region-qualified files are promotions, and only in a folder Kargo
  // promotes into: an abandoned one names a frozen version just as confidently.
  const wanted = locations
    .filter((l) => isKargoManaged(trees.get(locationKey(l)) ?? []))
    .flatMap((location) =>
      trees.get(locationKey(location)).flatMap((entry) => {
        const file = parsePromotionFile(entry.name);
        return file ? [{ location, file, entry }] : [];
      }),
    );

  const queued = new Set();
  const requests = [];
  for (const { location, entry } of wanted) {
    if (cache.has(entry.oid) || queued.has(entry.oid)) continue;
    queued.add(entry.oid);
    requests.push({ location, file: entry.name, oid: entry.oid });
  }
  const built = blobsQuery(requests);
  if (built) {
    const texts = decodeBlobs(await post({ token, fetchImpl, ...built }), requests);
    for (const { oid } of requests) {
      if (texts.has(oid)) cache.set(oid, stableVersion(texts.get(oid)));
    }
  }

  // Pruned to what is still in play, so the cache cannot grow without bound as versions move on.
  const live = new Set(wanted.map((w) => w.entry.oid));
  for (const oid of cache.keys()) if (!live.has(oid)) cache.delete(oid);

  const out = new Map();
  for (const { location, file, entry } of wanted) {
    const raw = cache.get(entry.oid);
    if (!raw) continue;
    // Kargo may write `v5.63.0` while the release is compared by bare version.
    const version = stripVersion(raw);
    const key = locationKey(location);
    out.set(key, [...(out.get(key) ?? []), { file, version }]);
  }
  return out;
}

export async function fetchTagReleases({ token, fetchImpl = fetch, requests }) {
  const built = tagReleasesQuery(requests);
  if (!built) return {};
  return decodeTagReleases(await post({ token, fetchImpl, ...built }), requests);
}

export { locationKey };

// Carried across polls: where each repository deploys (discovered once, even if
// the answer is "nowhere"), parsed blobs by oid, and the last good promotions.
export function newDeploymentsState() {
  return { locations: {}, blobCache: new Map(), promotions: {}, promotedReleases: {} };
}

// Deduplicated by tag: a version can be both inside the depth and asked for by
// name, and the same release twice would be compared twice.
export function mergeReleases(fetched, identified) {
  const out = { ...fetched };
  for (const [repoId, extra] of Object.entries(identified)) {
    const inHand = out[repoId] ?? [];
    out[repoId] = [...inHand, ...extra.filter((r) => !inHand.some((h) => h.tagName === r.tagName))];
  }
  return out;
}

// Reads what each environment runs, for the repositories in view. Kept apart
// from the release lookup so the two fail independently: an unreachable
// deployments repository must still leave a row saying which version was cut,
// and promotions are replaced only on success so a flap does not blank chips
// that were right a minute ago.
export async function refreshDeployments({ token, fetchImpl = fetch, state, merged, releases }) {
  try {
    const repos = [...new Set(merged.map((m) => m.repo))];
    // Once per repository, ever — including one that turned out to deploy
    // nothing, which is stored as [] rather than re-searched against a rate-limited endpoint.
    for (const repo of repos) {
      if (!state.locations[repo]) state.locations[repo] = await discover({ token, fetchImpl, repo });
    }
    const locations = [...new Map(repos.flatMap((r) => state.locations[r]).map((l) => [locationKey(l), l])).values()];
    const byLocation = await fetchPromotions({ token, fetchImpl, locations, cache: state.blobCache });

    // Re-keyed onto the repository, so one backing several apps is answered across all of them.
    const resolved = {};
    for (const repo of repos) {
      const versions = state.locations[repo].flatMap((l) => byLocation.get(locationKey(l)) ?? []);
      if (versions.length) resolved[repo] = versions;
    }

    // A version the window's depth never reached cannot be matched to a release,
    // and an unmatched version is silently no chip at all: ask for it by name, once.
    const unidentified = unidentifiedVersions(merged, mergeReleases(releases, state.promotedReleases), resolved);
    const identified = await fetchTagReleases({ token, fetchImpl, requests: unidentified });

    // Both assigned together and only here: a failure above leaves both as the last good poll left them.
    const live = new Set(merged.map((m) => m.repositoryID));
    state.promotions = resolved;
    state.promotedReleases = Object.fromEntries(
      Object.entries(mergeReleases(state.promotedReleases, identified)).filter(([id]) => live.has(id)),
    );
  } catch {
    // Chips stay as the last good poll left them.
  }
}
