import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { AppUpdate, checkLatestRelease, pickWindowsRelease, sha256Of, verifyDigest, versionOfTag } from "../src/core/appUpdate.js";
import { parseChangelog, whatsNewEntries } from "../src/core/changelog.js";

// ---- Integrity --------------------------------------------------------------

test("a download is checked against the digest GitHub published, sha256: prefixed or bare, case-blind", () => {
  const bytes = Buffer.from("installer bytes");
  const hex = createHash("sha256").update(bytes).digest("hex");
  assert.equal(sha256Of(bytes), hex);
  assert.equal(verifyDigest(bytes, `sha256:${hex}`), true);
  assert.equal(verifyDigest(bytes, hex.toUpperCase()), true);
  assert.equal(verifyDigest(bytes, ` sha256:${hex} `), true);
  assert.equal(verifyDigest(Buffer.from("tampered"), `sha256:${hex}`), false);
});

test("it fails closed: no digest means something is wrong with the release, not that there is nothing to verify", () => {
  const bytes = Buffer.from("x");
  assert.equal(verifyDigest(bytes, null), false);
  assert.equal(verifyDigest(bytes, undefined), false);
  assert.equal(verifyDigest(bytes, ""), false);
  assert.equal(verifyDigest(bytes, "sha256:"), false);
});

// ---- Which release --------------------------------------------------------------

const asset = (name, over = {}) => ({ name, browser_download_url: `https://github.com/o/r/releases/download/x/${name}`, digest: "sha256:abc", ...over });
const rel = (tag, assets = [asset("PRMaster-Setup.exe")], over = {}) => ({ tag_name: tag, draft: false, prerelease: false, assets, ...over });

test("the Windows build has its own tags, so the macOS releases in the same repository are never offered to it", () => {
  assert.equal(versionOfTag("windows-v1.2.3"), "1.2.3");
  assert.equal(versionOfTag("windows-1.2.3"), "1.2.3");
  assert.equal(pickWindowsRelease([rel("v9.0.0"), rel("v8.0.0")]), null);
  assert.equal(pickWindowsRelease([rel("v9.0.0"), rel("windows-v0.2.0")]).version, "0.2.0");
});

test("the newest by version, numerically, ignoring drafts and prereleases", () => {
  const out = pickWindowsRelease([rel("windows-v0.9.0"), rel("windows-v0.10.0"), rel("windows-v1.0.0", undefined, { draft: true }), rel("windows-v2.0.0", undefined, { prerelease: true })]);
  assert.equal(out.version, "0.10.0"); // as strings, 0.9.0 would sort above it
});

test("the installer is found by exact name, never by position: a release also carries other files", () => {
  const out = pickWindowsRelease([rel("windows-v1.0.0", [asset("source.zip"), asset("PRMaster-Setup.exe", { digest: "sha256:ff" })])]);
  assert.deepEqual([out.assetURL, out.sha256], ["https://github.com/o/r/releases/download/x/PRMaster-Setup.exe", "sha256:ff"]);
  assert.throws(() => pickWindowsRelease([rel("windows-v1.0.0", [asset("source.zip")])]), /no installer/i);
});

test("an asset with no digest still decodes: refusing is the installer's job, where it can be reported", () => {
  assert.equal(pickWindowsRelease([rel("windows-v1.0.0", [asset("PRMaster-Setup.exe", { digest: undefined })])]).sha256, null);
});

// ---- Asking GitHub ----------------------------------------------------------

const respond = (status, json) => async (url, init) => ({ ok: status === 200, status, json: async () => json, seen: { url, init } });

test("the check reads the public releases without a credential: nothing is gained by sending one", async () => {
  let seen;
  const fetchImpl = async (url, init) => { seen = { url, init }; return { ok: true, status: 200, json: async () => [rel("windows-v1.0.0")] }; };
  const release = await checkLatestRelease({ fetchImpl, repo: "o/r" });
  assert.equal(seen.url, "https://api.github.com/repos/o/r/releases?per_page=30");
  assert.equal(seen.init.headers.Authorization, undefined);
  assert.equal(seen.init.headers["User-Agent"], "PRMaster");
  assert.equal(release.version, "1.0.0");
});

test("no release yet is the state before the first tag, not a fault; anything else names the status", async () => {
  assert.equal(await checkLatestRelease({ fetchImpl: respond(404, {}), repo: "o/r" }), null);
  assert.equal(await checkLatestRelease({ fetchImpl: respond(200, []), repo: "o/r" }), null);
  await assert.rejects(checkLatestRelease({ fetchImpl: respond(403, {}), repo: "o/r" }), /GitHub returned 403/);
});

// ---- The update state -------------------------------------------------------

const release = (version) => ({ tag: `windows-v${version}`, version, assetURL: "https://x/y.exe", sha256: "sha256:abc" });
const checker = (impl) => ({ latest: impl });

test("only a release newer than the running one is offered", async () => {
  const u = new AppUpdate({ currentVersion: "1.0.0", checker: checker(async () => release("1.1.0")) });
  await u.checkNow();
  assert.equal(u.availableRelease.version, "1.1.0");
  const same = new AppUpdate({ currentVersion: "1.1.0", checker: checker(async () => release("1.1.0")) });
  await same.checkNow();
  assert.equal(same.availableRelease, null);
});

test("no release yet leaves nothing on offer and no warning", async () => {
  const u = new AppUpdate({ currentVersion: "1.0.0", checker: checker(async () => null) });
  await u.checkNow();
  assert.deepEqual([u.availableRelease, u.lastCheckFailure], [null, null]);
});

test("a network flap does not retract an update the user was already being offered", async () => {
  let fail = false;
  const u = new AppUpdate({ currentVersion: "1.0.0", checker: checker(async () => { if (fail) throw new Error("GitHub returned 502"); return release("1.1.0"); }) });
  await u.checkNow();
  fail = true;
  await u.checkNow();
  assert.equal(u.availableRelease.version, "1.1.0");
  assert.equal(u.lastCheckFailure, "GitHub returned 502");
  fail = false;
  await u.checkNow();
  assert.equal(u.lastCheckFailure, null);
});

test("two overlapping checks do not both run", async () => {
  let calls = 0;
  let release1;
  const gate = new Promise((r) => (release1 = r));
  const u = new AppUpdate({ currentVersion: "1.0.0", checker: checker(async () => { calls++; await gate; return null; }) });
  const first = u.checkNow();
  await u.checkNow();
  release1();
  await first;
  assert.equal(calls, 1);
});

test("installing hands the offered release to the installer; a failure comes back and leaves the offer standing", async () => {
  const installed = [];
  const u = new AppUpdate({ currentVersion: "1.0.0", checker: checker(async () => release("1.1.0")), installer: { install: async (r) => { installed.push(r.version); throw new Error("the download was empty"); } } });
  await u.checkNow();
  await u.install();
  assert.deepEqual(installed, ["1.1.0"]);
  assert.equal(u.lastInstallFailure, "the download was empty");
  assert.equal(u.isInstalling, false);
  assert.equal(u.availableRelease.version, "1.1.0");
});

test("with no installer (debug data), nothing is offered to install", async () => {
  const u = new AppUpdate({ currentVersion: "1.0.0", checker: checker(async () => release("1.1.0")) });
  await u.checkNow();
  assert.equal(u.canInstall, false);
  await u.install();
  assert.equal(u.isInstalling, false);
});

// ---- The changelog ----------------------------------------------------------

const MARKDOWN = `# Changelog

Intro text that is not an entry.

## 0.3.0 — 2026-10-16

- Third thing
- Fourth thing
![shot](whats-new-0.3.0.png)

## 0.2.0 — 2026-10-01

- Second thing
![escape](../../secret.png)

## v0.1.0 — 2026-09-01

- First thing
`;

test("the changelog is read to the shape it is written in: a heading per version, bullets, one bare-named image", () => {
  const entries = parseChangelog(MARKDOWN);
  assert.deepEqual(entries.map((e) => [e.version, e.lines.length, e.image]), [["0.3.0", 2, "whats-new-0.3.0.png"], ["0.2.0", 1, null], ["0.1.0", 1, null]]);
  assert.deepEqual(entries[0].lines, ["Third thing", "Fourth thing"]);
});

test("an image path is refused rather than resolved, so a changelog cannot point the window at a file on disk", () => {
  assert.equal(parseChangelog(MARKDOWN)[1].image, null);
});

test("what a launch has to show: nothing on a fresh install or when already seen", () => {
  const entries = parseChangelog(MARKDOWN);
  assert.deepEqual(whatsNewEntries({ entries, current: "0.3.0", lastSeen: "0.2.0", isFirstRun: true }), []);
  assert.deepEqual(whatsNewEntries({ entries, current: "0.3.0", lastSeen: "0.3.0", isFirstRun: false }), []);
  assert.deepEqual(whatsNewEntries({ entries, current: "9.9.9", lastSeen: "0.1.0", isFirstRun: false }), []); // the changelog says nothing about this build
});

test("an upgrade shows everything missed up to the running version, newest first; none recorded speaks only for the current one", () => {
  const entries = parseChangelog(MARKDOWN);
  assert.deepEqual(whatsNewEntries({ entries, current: "0.3.0", lastSeen: "0.1.0", isFirstRun: false }).map((e) => e.version), ["0.3.0", "0.2.0"]);
  assert.deepEqual(whatsNewEntries({ entries, current: "0.2.0", lastSeen: "0.1.0", isFirstRun: false }).map((e) => e.version), ["0.2.0"]); // not a release from the future
  assert.deepEqual(whatsNewEntries({ entries, current: "0.3.0", lastSeen: null, isFirstRun: false }).map((e) => e.version), ["0.3.0"]);
});
