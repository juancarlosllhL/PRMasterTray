// Which version each environment runs, read from the deployments repositories.
// Port of Promotion.swift, AppDiscovery.swift and ReleaseVersion (AppRelease.swift).

// Apps pinned to the central clusters spell the same two environments cst/cpr.
// Anything else is left unrecognised rather than guessed: naming the wrong
// environment is worse than naming none.
const ENVIRONMENTS = { stg: "staging", cst: "staging", prd: "production", cpr: "production" };

// Only the region-qualified files are promotions. `values.yaml` carries a
// `stableVersion: 0.0.0` placeholder, so rejecting it keeps version zero out.
export function parsePromotionFile(name) {
  const parts = name.split(".");
  if (parts.length !== 4 || parts[0] !== "values" || parts[3] !== "yaml" || !parts[2]) return null;
  const environment = ENVIRONMENTS[parts[1]];
  return environment ? { environment, region: parts[2] } : null;
}

const unquote = (s) => s.replace(/^["']+|["']+$/g, "");

// Anchored at column 0 and stopping at the first whitespace: these files argue
// about versions in prose, and a mention in a comment or a sub-chart's own key
// must never read as the promoted version.
export function stableVersion(text) {
  const key = "stableVersion:";
  const line = text.split("\n").find((l) => l.startsWith(key));
  if (line === undefined) return null;
  const token = line.slice(key.length).trim().split(/\s+/)[0] ?? "";
  return unquote(token) || null;
}

export const stripVersion = (tag) => (tag.startsWith("v") ? tag.slice(1) : tag);

const components = (version) => version.split(".").map((p) => (/^\d+$/.test(p) ? Number(p) : 0));

// Component-wise as integers: "1.10.0" sorts below "1.9.0" as a string. A
// missing or non-numeric component counts as zero, so a tag like `latest`
// cannot present itself as an upgrade.
export function isNewer(remote, local) {
  const a = components(remote);
  const b = components(local);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return false;
}

// What one environment runs across its regions. Every region's version is kept
// whole so "did the change reach this environment" can be answered per region.
// Staging first, so a row reads in the order a change travels; an environment
// nobody promoted to is left out.
export function collapse(promoted) {
  return ["staging", "production"].flatMap((environment) => {
    const versions = [...new Set(promoted.filter((p) => p.file.environment === environment).map((p) => p.version))];
    if (versions.length === 0) return [];
    // The lowest, because a rollout that reached one region has not reached the environment.
    const displayVersion = versions.reduce((low, v) => (isNewer(low, v) ? v : low));
    return [{ environment, versions, displayVersion, regionsAgree: versions.length <= 1 }];
  });
}

// ---- Finding which app folders belong to a service repository -------------
//
// The mapping cannot be derived from names: one repository pushes
// `lec-analytics-asset-consumer-v2` into the folder `analytics-assets-consumer-v2`,
// whose chart calls itself `lec-analytics-assets-consumer-v2`. The image name is
// the one string that appears verbatim on both sides.

export function imageNames(circleCiConfig) {
  const key = "repository:";
  const lines = circleCiConfig.split("\n");

  // Beyond the macOS app, which reads the value literally: several of these
  // configs write `repository: *name` against `&name image-name` declared once.
  const anchors = new Map();
  for (const line of lines) {
    const match = line.match(/&([\w-]+)\s+(\S+)/);
    if (match) anchors.set(match[1], unquote(match[2]));
  }

  const names = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed.startsWith(key)) continue;
    let name = unquote(trimmed.slice(key.length).trim().split(/\s+/)[0] ?? "");
    if (name.startsWith("*")) name = anchors.get(name.slice(1)) ?? ""; // an alias with no anchor names nothing
    if (name && !names.includes(name)) names.push(name);
  }
  return names;
}

// Code search is token-based, so an image name also matches files that only
// contain it inside something else (a secretName in an unrelated service). Only
// a declaration counts; three keys are needed, because appName and the image
// disagree when a chart is named plural and its image singular, and only the
// Kargo subscription is present in a kargo/values.yaml.
export function declaresImage(image, text) {
  for (const line of text.split("\n")) {
    const trimmed = line.trim().replace(/^[- ]+|[- ]+$/g, "");
    const colon = trimmed.indexOf(":");
    if (colon < 0) continue;
    const key = trimmed.slice(0, colon);
    if (key !== "appName" && key !== "repositoryName" && key !== "imageTag") continue;
    const value = unquote(trimmed.slice(colon + 1).trim());
    if (value.split("/").pop() === image) return true; // the tag is a registry path
  }
  return false;
}

// A decommissioned folder keeps its chart and values files, so it goes on naming
// a `stableVersion` frozen on the day it was switched off. A version nobody
// promoted is worse than no version: it cannot be matched to a release, and one
// unanswerable region silences the environment for the live app beside it.
export const isKargoManaged = (entries) => entries.some((e) => e.name === "kargo");

// `.stages/` holds a rendered copy of every app per cluster. Kargo never writes
// there, so a hit inside it would multiply each app by the number of clusters.
export function locationsFromSearchPaths(hits) {
  const seen = new Set();
  const out = [];
  for (const { repo, path } of hits) {
    if (path.startsWith(".stages/")) continue;
    const appPath = path.split("/")[0];
    if (appPath.endsWith(".yaml")) continue;
    const key = `${repo}|${appPath}`;
    if (!seen.has(key)) {
      seen.add(key);
      out.push({ deploymentsRepo: repo, appPath });
    }
  }
  return out;
}
