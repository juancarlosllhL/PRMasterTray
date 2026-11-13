// The app replacing itself: finding the newest release, verifying what was
// downloaded, and the state the update row reads. Port of AppRelease.swift,
// ReleaseClient.swift, ReleaseIntegrity.swift and AppUpdateStore.swift.
import { createHash } from "node:crypto";
import { isNewer } from "./promotion.js";

// The Windows build is released under its own tags, so the macOS releases in the
// same repository are never offered to it (and vice versa).
const TAG_PREFIX = "windows-";
const INSTALLER = "PRMaster-Setup.exe";

export const versionOfTag = (tag) => tag.replace(new RegExp(`^${TAG_PREFIX}`), "").replace(/^v/, "");

export const sha256Of = (bytes) => createHash("sha256").update(bytes).digest("hex");

// The only meaningful integrity control available: the installer is unsigned, so
// nothing says *who* built it, and the digest, read from the API over TLS, is what
// pins the bytes to the ones the release workflow uploaded. Fails closed: a missing
// or empty digest means something is wrong with the release, not that there is
// nothing to verify.
export function verifyDigest(bytes, expected) {
  if (!expected) return false;
  const want = expected.toLowerCase().replace("sha256:", "").trim();
  return want !== "" && sha256Of(bytes) === want;
}

// The newest published release of the Windows build. null when there is none yet.
// The installer is found by exact name, never by position: a real release also
// carries source archives and whatever else was attached.
export function pickWindowsRelease(releases) {
  const newest = releases
    .filter((r) => r.tag_name.startsWith(TAG_PREFIX) && !r.draft && !r.prerelease)
    .sort((a, b) => (isNewer(versionOfTag(a.tag_name), versionOfTag(b.tag_name)) ? -1 : isNewer(versionOfTag(b.tag_name), versionOfTag(a.tag_name)) ? 1 : 0))[0];
  if (!newest) return null;
  const asset = newest.assets.find((a) => a.name === INSTALLER);
  if (!asset) throw new Error(`The ${newest.tag_name} release carries no installer (${INSTALLER}).`);
  // Absent on assets uploaded before GitHub began publishing digests: kept null so
  // the release still decodes, and the installer refuses to run without it.
  return { tag: newest.tag_name, version: versionOfTag(newest.tag_name), assetURL: asset.browser_download_url, sha256: asset.digest ?? null };
}

// REST, deliberately unauthenticated: it reads a public repository, and sending a
// credential where none is needed only widens the blast radius.
// `repo` is `owner/name`, from package.json: there is no default to be quietly wrong.
export async function checkLatestRelease({ fetchImpl = fetch, repo }) {
  const res = await fetchImpl(`https://api.github.com/repos/${repo}/releases?per_page=30`, {
    headers: { Accept: "application/vnd.github+json", "User-Agent": "PRMaster" },
  });
  if (res.status === 404) return null; // the state a repository is in until the first tag is pushed
  // Unlike GraphQL, REST does not report application failures in a 200 body, so a
  // non-200 is the whole story: a 403 is the rate limit, a 5xx GitHub being down.
  if (!res.ok) throw new Error(`GitHub returned ${res.status}`);
  return pickWindowsRelease(await res.json());
}

// Observable state behind the update row. Kept apart from the pull request poll:
// checking for a new build has nothing to do with it, runs on a different clock
// (30 minutes against a 60-per-hour unauthenticated budget), and must not be able
// to disturb the list when it fails.
export class AppUpdate {
  // checker: { latest() } -> release | null; installer: { install(release) } | null,
  // which disables installing outright (as under debug data).
  constructor({ currentVersion, checker, installer = null }) {
    this.currentVersion = currentVersion;
    this.checker = checker;
    this.installer = installer;
    this.availableRelease = null;
    this.isChecking = false;
    this.isInstalling = false;
    this.lastCheckFailure = null;
    this.lastInstallFailure = null;
    this.onChange = () => {};
  }

  get canInstall() {
    return this.installer !== null;
  }

  async checkNow() {
    // Two call sites reach here (the poll and "Check for Updates…"): without this
    // the slower of two overlapping checks would win.
    if (this.isChecking) return;
    this.isChecking = true;
    try {
      const release = await this.checker.latest();
      this.availableRelease = release && isNewer(release.version, this.currentVersion) ? release : null;
      this.lastCheckFailure = null;
    } catch (e) {
      // availableRelease is deliberately untouched: a network flap must not retract an update already on offer.
      this.lastCheckFailure = e.message;
    } finally {
      this.isChecking = false;
      this.onChange();
    }
  }

  // On success this does not return: the installer ends the process. Only a
  // failure comes back, and it leaves the offer standing so the user can try again.
  async install() {
    if (this.isInstalling || !this.installer || !this.availableRelease) return;
    this.isInstalling = true;
    this.lastInstallFailure = null;
    this.onChange();
    try {
      await this.installer.install(this.availableRelease);
    } catch (e) {
      this.lastInstallFailure = e.message;
      this.isInstalling = false;
      this.onChange();
    }
  }
}
