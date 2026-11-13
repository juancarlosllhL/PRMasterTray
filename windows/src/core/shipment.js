// What became of a merged pull request. Port of Shipment.swift (without the
// stg/prod environments) and MergedWindow.swift. Pure: every input is a snapshot.
//
// A release's time is its publication, not its tag commit's date: CI cuts a
// release from a merge, so GitHub can date it before the merge it contains.
import { collapse, stripVersion } from "./promotion.js";

const cutAt = (release) => new Date(release.publishedAt ?? release.createdAt);

export const containmentKey = (prId, tagName) => `${prId}|${tagName}`;

// Window depth is a correctness matter, not tuning: containment is only decided
// among the releases actually fetched, and a week-old merge in a repository that
// ships several times a day would otherwise name a later release than the first
// one containing it.
export function releaseDepth(windowDays) {
  if (windowDays == null) return 0;
  return windowDays <= 1 ? 5 : windowDays <= 3 ? 20 : 50;
}

// A merge dated in the future counts as recent: that is a clock trailing
// GitHub's, and hiding a merge that has just landed is the one wrong answer.
export function isRecent(mergedAt, now, windowDays) {
  if (windowDays == null) return false;
  return now - new Date(mergedAt) <= windowDays * 86_400_000;
}

// A full timestamp rather than a date: a date would widen the window by up to
// 48 hours and the list would disagree with isRecent about half its rows.
export function mergedQualifier(now, windowDays) {
  const cutoff = new Date(now.getTime() - (windowDays ?? 0) * 86_400_000);
  return `merged:>${cutoff.toISOString().replace(/\.\d+Z$/, "Z")}`;
}

// Prefers a whole CircleCI workflow over one job inside it; among equals, still
// running first, then failing. The fallback keeps a row from doing nothing.
export function pickLink(contexts, fallback) {
  const linked = contexts.filter((c) => c.url);
  const workflows = linked.filter((c) => c.isWorkflow);
  const preferred = workflows.length ? workflows : linked;
  const running = preferred.find((c) => c.state === "PENDING" || c.state === "EXPECTED");
  const failing = preferred.find((c) => c.state === "FAILURE" || c.state === "ERROR");
  return (running ?? failing ?? preferred[0])?.url ?? fallback;
}

const isFailing = (c) => c.state === "FAILURE" || c.state === "ERROR";

function statusFor(pr, releases, containment) {
  if (!pr.mergeCommitOid) return { kind: "pending" };
  const link = pickLink(pr.contexts, pr.url);

  // The rollup is the authority, since it covers context types dropped at
  // decode; a named failing check counts too, because evidence outranks a summary.
  const failing = pr.contexts.find(isFailing);
  if (failing) return { kind: "failed", name: failing.name, url: link };
  if (pr.rollupState === "FAILURE" || pr.rollupState === "ERROR") return { kind: "failed", name: "a check", url: link };
  if (pr.rollupState === "PENDING" || pr.rollupState === "EXPECTED") return { kind: "building", url: link };

  // The earliest release containing the merge: the version the change first
  // appeared in, not the newest one that happens to include it.
  const first = [...releases]
    .sort((a, b) => cutAt(a) - cutAt(b))
    .find((r) => containment.get(containmentKey(pr.id, r.tagName)) === true);
  if (first) return { kind: "released", version: first.tagName, url: first.url };

  // Green, but no release carries it yet. A repository that cuts none has
  // nothing pending, so it rests at pending rather than claiming to be mid-flight.
  return releases.length ? { kind: "building", url: link } : { kind: "pending" };
}

// Whether the release a region runs contains the merge. null when nothing
// identifies that version or the comparison has not come back; a release cut
// before the merge is settled from the clock alone, without spending a request.
function carries(pr, version, releases, containment) {
  const release = releases.find((r) => stripVersion(r.tagName) === version);
  if (!release) return null;
  if (cutAt(release) < new Date(pr.mergedAt)) return false;
  return containment.get(containmentKey(pr.id, release.tagName)) ?? null;
}

// Decided by containment, never by comparing version numbers: an environment can
// sit on a higher version cut from another branch that lacks this merge. It
// carries the change only when every region does; a region proven to lack it
// settles the environment even if another has no answer — proof outranks an
// unknown, but an unknown is never rounded into a yes.
function environmentsFor(pr, promoted, releases, containment) {
  return collapse(promoted).map(({ environment, versions, displayVersion, regionsAgree }) => {
    const answers = versions.map((v) => carries(pr, v, releases, containment));
    const version = displayVersion ?? "";
    const kind = answers.includes(false) ? "awaiting" : answers.includes(null) ? "unknown" : "carrying";
    return { environment, status: kind === "unknown" ? { kind } : { kind, version }, regionsAgree };
  });
}

// promotions: every region of every app that ships from a repository, keyed by repo.
export function resolve({ merged, releases, containment, promotions = {} }) {
  return merged.map((pr) => {
    const repoReleases = releases[pr.repositoryID] ?? [];
    return {
      pr,
      status: statusFor(pr, repoReleases, containment),
      environments: environmentsFor(pr, promotions[pr.repo] ?? [], repoReleases, containment),
    };
  });
}

// The promoted versions no fetched release accounts for. The window's depth
// reaches only the most recent releases, and an environment can be many behind
// that — which would render as no chip rather than as a lag. Deduplicated per
// repository and version: every merge in a repository sees the same environments.
export function unidentifiedVersions(merged, releases, promotions) {
  const seen = new Set();
  const out = [];
  for (const pr of merged) {
    const identified = new Set((releases[pr.repositoryID] ?? []).map((r) => stripVersion(r.tagName)));
    for (const { version } of promotions[pr.repo] ?? []) {
      const key = `${pr.repo}|${pr.repositoryID}|${version}`;
      if (identified.has(version) || seen.has(key)) continue;
      seen.add(key);
      out.push({ repo: pr.repo, repositoryID: pr.repositoryID, version });
    }
  }
  return out;
}

// The (merge, release) pairs worth a containment request. A release cut before
// the merge cannot contain it, so asking would spend a request to be told what
// the clock already says.
export function candidates(merged, releases) {
  return merged.flatMap((pr) => {
    if (!pr.mergeCommitOid) return [];
    const mergedAt = new Date(pr.mergedAt);
    return (releases[pr.repositoryID] ?? [])
      .filter((r) => cutAt(r) >= mergedAt)
      .sort((a, b) => cutAt(a) - cutAt(b))
      .map((release) => ({ pr, release }));
  });
}
