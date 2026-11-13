import { test } from "node:test";
import assert from "node:assert/strict";
import {
  blobsQuery,
  decodeBlobs,
  decodeTagReleases,
  decodeTrees,
  discover,
  fetchPromotions,
  tagReleasesQuery,
  treesQuery,
} from "../src/core/deployments.js";

const loc = (appPath = "chat", deploymentsRepo = "o/deploy") => ({ deploymentsRepo, appPath });

test("trees query: one aliased field per folder, every remote value bound as a variable", () => {
  assert.equal(treesQuery([]), null);
  const { query, variables } = treesQuery([loc("chat"), loc("other", "o/two")]);
  assert.deepEqual(variables, {
    owner0: "o", name0: "deploy", tree0: "HEAD:chat", // HEAD, not main: default branches are not uniform
    owner1: "o", name1: "two", tree1: "HEAD:other",
  });
  assert.doesNotMatch(query, /deploy|chat|two/);
  assert.match(query, /t1: repository\(owner: \$owner1, name: \$name1\)/);
});

test("trees decode per folder; one that does not resolve is omitted, not recorded as empty", () => {
  const body = { data: { t0: { object: { entries: [{ name: "kargo", object: { oid: "k" } }, { name: "values.stg.eu.yaml", object: { oid: "v" } }, { name: "weird", object: null }] } }, t1: { object: null }, t2: null } };
  const out = decodeTrees(body, [loc("a"), loc("b"), loc("c")]);
  assert.deepEqual(out.get("o/deploy|a"), [{ name: "kargo", oid: "k" }, { name: "values.stg.eu.yaml", oid: "v" }]);
  assert.equal(out.has("o/deploy|b"), false);
  assert.equal(out.has("o/deploy|c"), false);
});

const blobReq = (file, oid) => ({ location: loc(), file, oid });

test("blob query asks for exactly the files given, and decodes text by oid", () => {
  assert.equal(blobsQuery([]), null);
  const reqs = [blobReq("values.stg.eu.yaml", "o1"), blobReq("values.prd.eu.yaml", "o2")];
  const { variables } = blobsQuery(reqs);
  assert.equal(variables.blob1, "HEAD:chat/values.prd.eu.yaml");
  const out = decodeBlobs({ data: { b0: { object: { text: "stableVersion: 1.0.0" } }, b1: { object: null } } }, reqs);
  assert.deepEqual([...out], [["o1", "stableVersion: 1.0.0"]]);
});

test("tag releases ask for both spellings of the tag and take whichever exists", () => {
  const reqs = [{ repo: "acme/w", repositoryID: "R_1", version: "3.31.1" }, { repo: "acme/x", repositoryID: "R_2", version: "1.0.0" }];
  assert.equal(tagReleasesQuery([]), null);
  const { variables } = tagReleasesQuery(reqs);
  assert.deepEqual([variables.prefixed0, variables.bare0], ["v3.31.1", "3.31.1"]);
  const rel = (tagName, over = {}) => ({ tagName, url: `https://github.com/acme/w/releases/tag/${tagName}`, createdAt: "2026-10-29T10:00:00Z", publishedAt: null, isDraft: false, tagCommit: { oid: "t" }, ...over });
  const out = decodeTagReleases(
    { data: { r0: { prefixed: rel("v3.31.1"), bare: null }, r1: { prefixed: null, bare: null } } },
    reqs,
  );
  assert.deepEqual(Object.keys(out), ["R_1"]); // a version neither spelling resolves is omitted
  assert.equal(out.R_1[0].tagName, "v3.31.1");
  const draft = decodeTagReleases({ data: { r0: { prefixed: rel("v3.31.1", { isDraft: true }), bare: null } } }, [reqs[0]]);
  assert.deepEqual(draft, {});
});

// A fake GitHub: GraphQL by the alias each document uses, REST code search by URL.
function fakeGitHub({ files = {}, search = [], trees = {}, blobs = {} } = {}) {
  const calls = { graphql: [], rest: [] };
  const fetchImpl = async (url, init) => {
    if (url.startsWith("https://api.github.com/search/code")) {
      calls.rest.push(url);
      return { ok: true, status: 200, json: async () => ({ items: search.map(({ repo, path }) => ({ path, repository: { full_name: repo } })) }) };
    }
    const { query, variables } = JSON.parse(init.body);
    calls.graphql.push({ query, variables });
    const data = {};
    if (query.includes("$expression")) {
      data.repository = { object: files[variables.expression] === undefined ? null : { text: files[variables.expression] } };
    } else {
      for (const m of query.matchAll(/\b([tb])(\d+): repository/g)) {
        const [, kind, i] = m;
        if (kind === "t") data[`t${i}`] = trees[variables[`tree${i}`]] ?? null;
        else data[`b${i}`] = { object: { text: blobs[variables[`blob${i}`]] ?? null } };
      }
    }
    return { ok: true, status: 200, json: async () => ({ data }) };
  };
  return { fetchImpl, calls };
}

test("discover joins a service repo to its app folders through the image name", async () => {
  const gh = fakeGitHub({
    files: {
      "HEAD:.circleci/config.yml": "steps:\n  - push:\n      repository: lec-ai-chat\n",
      "HEAD:chat/values.yaml": "appName: lec-ai-chat\n",
      "HEAD:chat/kargo/values.yaml": "imageTag: reg.io/x/lec-ai-chat\n",
      "HEAD:noise/values.yaml": "secretName: ch-lec-ai-chat-credentials\n",
    },
    search: [
      { repo: "o/deploy", path: "chat/values.yaml" },
      { repo: "o/deploy", path: "chat/kargo/values.yaml" },
      { repo: "o/deploy", path: "noise/values.yaml" },
      { repo: "o/deploy", path: ".stages/eu/chat/values.yaml" },
    ],
  });
  const out = await discover({ token: "t", fetchImpl: gh.fetchImpl, repo: "Lansweeper/LECAIChat" });
  assert.deepEqual(out, [loc("chat")]);
  assert.match(gh.calls.rest[0], /org%3ALansweeper|org:Lansweeper/);
  // .stages is dropped before being read: it would declare the image just as truthfully.
  assert.equal(gh.calls.graphql.some((c) => c.variables.expression?.includes(".stages")), false);
});

test("a repository with no CircleCI config deploys nothing — an empty answer, not an error", async () => {
  const gh = fakeGitHub();
  assert.deepEqual(await discover({ token: "t", fetchImpl: gh.fetchImpl, repo: "o/none" }), []);
  assert.equal(gh.calls.rest.length, 0);
});

const kargoTree = (...names) => ({ object: { entries: names.map((name, i) => ({ name, object: { oid: `${name}#${i}` } })) } });

test("promotions: only Kargo-managed folders, only region files, and unchanged blobs are never re-read", async () => {
  const gh = fakeGitHub({
    trees: {
      "HEAD:live": kargoTree("kargo", "values.yaml", "values.stg.eu.yaml", "values.prd.eu.yaml"),
      "HEAD:dead": kargoTree("values.stg.eu.yaml"),
    },
    blobs: {
      "HEAD:live/values.stg.eu.yaml": "stableVersion: 1.5.0\n",
      "HEAD:live/values.prd.eu.yaml": "stableVersion: 1.4.0\n",
      "HEAD:dead/values.stg.eu.yaml": "stableVersion: 0.0.1\n",
    },
  });
  const cache = new Map();
  const locations = [loc("live"), loc("dead")];
  const out = await fetchPromotions({ token: "t", fetchImpl: gh.fetchImpl, locations, cache });
  assert.deepEqual(out.get("o/deploy|live").map((p) => [p.file.environment, p.version]), [["staging", "1.5.0"], ["production", "1.4.0"]]);
  assert.equal(out.has("o/deploy|dead"), false); // frozen at whatever was promoted the day it was switched off

  const asked = gh.calls.graphql.filter((c) => /b\d+: repository/.test(c.query)).length;
  await fetchPromotions({ token: "t", fetchImpl: gh.fetchImpl, locations, cache });
  assert.equal(gh.calls.graphql.filter((c) => /b\d+: repository/.test(c.query)).length, asked); // steady state: tree listing only
});

test("a file that names no version is not re-read every poll either", async () => {
  const gh = fakeGitHub({ trees: { "HEAD:live": kargoTree("kargo", "values.stg.eu.yaml") }, blobs: { "HEAD:live/values.stg.eu.yaml": "nothing: here\n" } });
  const cache = new Map();
  const first = await fetchPromotions({ token: "t", fetchImpl: gh.fetchImpl, locations: [loc("live")], cache });
  assert.equal(first.has("o/deploy|live"), false);
  const before = gh.calls.graphql.length;
  await fetchPromotions({ token: "t", fetchImpl: gh.fetchImpl, locations: [loc("live")], cache });
  assert.equal(gh.calls.graphql.length - before, 1); // the tree, nothing else
});

test("the cache is pruned to what is still in play", async () => {
  const gh = fakeGitHub({ trees: { "HEAD:live": kargoTree("kargo", "values.stg.eu.yaml") }, blobs: { "HEAD:live/values.stg.eu.yaml": "stableVersion: 1.0.0" } });
  const cache = new Map([["stale-oid", "9.9.9"]]);
  await fetchPromotions({ token: "t", fetchImpl: gh.fetchImpl, locations: [loc("live")], cache });
  assert.equal(cache.has("stale-oid"), false);
  assert.equal(cache.size, 1);
});

test("a stableVersion written with the v prefix still matches a release tag", async () => {
  const gh = fakeGitHub({ trees: { "HEAD:live": kargoTree("kargo", "values.stg.eu.yaml") }, blobs: { "HEAD:live/values.stg.eu.yaml": "stableVersion: v5.63.0\n" } });
  const out = await fetchPromotions({ token: "t", fetchImpl: gh.fetchImpl, locations: [loc("live")], cache: new Map() });
  assert.equal(out.get("o/deploy|live")[0].version, "5.63.0");
});
