import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeFiles, decodeMeta, loadDiff, mergeTarget, observeLive, setViewed } from "../src/core/diff.js";

const file = (over = {}) => ({
  filename: "src/a.js",
  previous_filename: null,
  status: "modified",
  additions: 1,
  deletions: 1,
  changes: 2,
  patch: "@@ -1,1 +1,1 @@\n-a\n+b",
  ...over,
});

test("a REST file becomes a diff file with parsed hunks", () => {
  const [f] = decodeFiles([file({ status: "renamed", previous_filename: "src/old.js" })]);
  assert.deepEqual({ path: f.path, previousPath: f.previousPath, change: f.change, additions: f.additions, deletions: f.deletions, viewed: f.viewed }, { path: "src/a.js", previousPath: "src/old.js", change: "renamed", additions: 1, deletions: 1, viewed: "UNVIEWED" });
  assert.equal(f.content.kind, "hunks");
  assert.equal(f.content.hunks[0].lines.length, 2);
});

test("an unknown status must not cost the reader the whole diff", () => {
  assert.equal(decodeFiles([file({ status: "something_new" })])[0].change, "modified");
});

test("no patch: too large when changes were counted, nothing to show otherwise", () => {
  assert.deepEqual(decodeFiles([file({ patch: undefined, changes: 900 })])[0].content, { kind: "omitted", reason: "tooLarge" });
  assert.deepEqual(decodeFiles([file({ patch: undefined, changes: 0 })])[0].content, { kind: "omitted", reason: "noTextChanges" });
});

test("a patch that disagrees with its own header is shown as unparseable, not misnumbered", () => {
  assert.deepEqual(decodeFiles([file({ patch: "@@ -1,5 +1,5 @@\n-a" })])[0].content, { kind: "omitted", reason: "unparseable" });
});

const metaBody = (over = {}, nodes = [{ path: "src/a.js", viewerViewedState: "VIEWED" }], page = { hasNextPage: false, endCursor: null }) => ({
  data: { repository: { pullRequest: { id: "PR_1", baseRefOid: "base", headRefOid: "head", changedFiles: 1, bodyHTML: "<p>hi</p>", files: { pageInfo: page, nodes }, ...over } } },
});

test("meta carries what the diff is pinned to, plus viewed states", () => {
  const m = decodeMeta(metaBody());
  assert.deepEqual({ id: m.id, baseOid: m.baseOid, headOid: m.headOid, changedFiles: m.changedFiles, descriptionHTML: m.descriptionHTML, nextCursor: m.nextCursor }, { id: "PR_1", baseOid: "base", headOid: "head", changedFiles: 1, descriptionHTML: "<p>hi</p>", nextCursor: null });
  assert.equal(m.viewed.get("src/a.js"), "VIEWED");
});

test("an empty description is none, and a missing pull request is an error", () => {
  assert.equal(decodeMeta(metaBody({ bodyHTML: "" })).descriptionHTML, null);
  assert.throws(() => decodeMeta({ data: { repository: { pullRequest: null } } }), /not found/);
  assert.throws(() => decodeMeta({ errors: [{ message: "boom" }] }), /boom/);
});

// A GitHub that serves one pull request's metadata, compare and file listing.
function github({ changedFiles = 1, files = [file()], pages, headSequence = ["head"], viewed = {} } = {}) {
  const log = { urls: [] };
  let heads = [...headSequence];
  const fetchImpl = async (url, init) => {
    const ok = (json) => ({ ok: true, status: 200, json: async () => json });
    if (!init?.body) {
      log.urls.push(url);
      if (url.includes("/compare/")) return ok({ files });
      const page = Number(new URL(url).searchParams.get("page"));
      return ok((pages ?? [files])[page - 1] ?? []);
    }
    const { query, variables } = JSON.parse(init.body);
    if (query.includes("markFileAsViewed") || query.includes("unmarkFileAsViewed")) {
      log.viewedCall = { query, variables };
      return ok({ data: { markFileAsViewed: { clientMutationId: null } } });
    }
    if (/pullRequest\(number: \$number\) \{ headRefOid \}/.test(query)) return ok({ data: { repository: { pullRequest: { headRefOid: heads.shift() ?? "head" } } } });
    if (query.includes("object(oid: $oid)")) return ok({ data: { repository: { object: { file: { object: { text: "*.lock linguist-generated" } } } } } });
    return ok(metaBody({ changedFiles }, Object.entries(viewed).map(([path, viewerViewedState]) => ({ path, viewerViewedState }))));
  };
  return { fetchImpl, log };
}

test("a small diff is read pinned by SHA, so a push after the metadata cannot change it", async () => {
  const gh = github({ viewed: { "src/a.js": "VIEWED" } });
  const d = await loadDiff({ token: "t", fetchImpl: gh.fetchImpl, repo: "acme/w", number: 5 });
  assert.equal(gh.log.urls[0], "https://api.github.com/repos/acme/w/compare/base...head");
  assert.deepEqual({ id: d.pullRequestID, base: d.baseOid, head: d.headOid, truncated: d.isTruncated }, { id: "PR_1", base: "base", head: "head", truncated: false });
  assert.equal(d.files[0].viewed, "VIEWED");
  assert.equal(d.gitAttributes, "*.lock linguist-generated");
});

test("over 300 files the pull request listing is paged, then the head is checked", async () => {
  const page = (n) => Array.from({ length: n }, (_, i) => file({ filename: `f${i}.js` }));
  const gh = github({ changedFiles: 301, pages: [page(100), page(100), page(100), page(1)] });
  const d = await loadDiff({ token: "t", fetchImpl: gh.fetchImpl, repo: "acme/w", number: 5 });
  assert.equal(d.files.length, 301);
  assert.equal(gh.log.urls.filter((u) => u.includes("/pulls/5/files")).length, 4); // stops at the first short page
});

test("a head that moved during a paged read triggers one retry; a second time it gives up", async () => {
  const many = Array.from({ length: 3 }, () => file());
  const retry = github({ changedFiles: 301, pages: [many], headSequence: ["moved", "head"] });
  await loadDiff({ token: "t", fetchImpl: retry.fetchImpl, repo: "acme/w", number: 5 });
  const stuck = github({ changedFiles: 301, pages: [many], headSequence: ["moved", "moved"] });
  await assert.rejects(loadDiff({ token: "t", fetchImpl: stuck.fetchImpl, repo: "acme/w", number: 5 }), /moved/);
});

test("pull requests over 3000 files are marked truncated, not shown as complete", async () => {
  const gh = github({ changedFiles: 3001, pages: [[file()]] });
  assert.equal((await loadDiff({ token: "t", fetchImpl: gh.fetchImpl, repo: "acme/w", number: 5 })).isTruncated, true);
});

test("losing .gitattributes must not cost the diff", async () => {
  const gh = github();
  const broken = async (url, init) => {
    if (init?.body && JSON.parse(init.body).query.includes("object(oid: $oid)")) throw new Error("network down");
    return gh.fetchImpl(url, init);
  };
  const d = await loadDiff({ token: "t", fetchImpl: broken, repo: "acme/w", number: 5 });
  assert.equal(d.gitAttributes, null);
  assert.equal(d.files.length, 1);
});

test("marking viewed and unmarking use GitHub's own mutations", async () => {
  const gh = github();
  await setViewed({ token: "t", fetchImpl: gh.fetchImpl, pullRequestID: "PR_1", path: "src/a.js", viewed: true });
  assert.match(gh.log.viewedCall.query, /markFileAsViewed/);
  assert.deepEqual(gh.log.viewedCall.variables, { id: "PR_1", path: "src/a.js" });
  await setViewed({ token: "t", fetchImpl: gh.fetchImpl, pullRequestID: "PR_1", path: "src/a.js", viewed: false });
  assert.match(gh.log.viewedCall.query, /unmarkFileAsViewed/);
});

test("a viewed toggle GitHub does not confirm is an error, not a silent success", async () => {
  const fetchImpl = async () => ({ ok: true, status: 200, json: async () => ({ data: { markFileAsViewed: null } }) });
  await assert.rejects(setViewed({ token: "t", fetchImpl, pullRequestID: "PR_1", path: "a", viewed: true }), /did not confirm/);
});

// ---- Merge and approve act on exactly what was read ------------------------

const loaded = { pullRequestID: "PR_1", headOid: "head", isTruncated: false };

test("the live head decides whether what was read is still what GitHub would act on", () => {
  assert.equal(observeLive(loaded, "head"), "loaded");
  assert.equal(observeLive(loaded, "newer"), "headMoved");
  assert.equal(observeLive(loaded, null), "closed"); // merged or closed elsewhere
  assert.equal(observeLive(loaded, undefined), "loaded"); // not heard from yet: nothing to contradict it
});

test("merge target exists only for a loaded, ready, untruncated diff", () => {
  assert.deepEqual(mergeTarget({ phase: "loaded", isReady: true, diff: loaded }), { id: "PR_1", oid: "head" });
  assert.equal(mergeTarget({ phase: "headMoved", isReady: true, diff: loaded }), null);
  assert.equal(mergeTarget({ phase: "closed", isReady: true, diff: loaded }), null);
  assert.equal(mergeTarget({ phase: "loaded", isReady: false, diff: loaded }), null);
  assert.equal(mergeTarget({ phase: "loaded", isReady: true, diff: { ...loaded, isTruncated: true } }), null); // part of it was never shown
  assert.equal(mergeTarget({ phase: "loading", isReady: true, diff: null }), null);
});
