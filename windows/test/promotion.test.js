import { test } from "node:test";
import assert from "node:assert/strict";
import {
  collapse,
  declaresImage,
  imageNames,
  isKargoManaged,
  isNewer,
  locationsFromSearchPaths,
  parsePromotionFile,
  stableVersion,
  stripVersion,
} from "../src/core/promotion.js";

test("only region-qualified values files are promotions", () => {
  assert.deepEqual(parsePromotionFile("values.stg.eu1.yaml"), { environment: "staging", region: "eu1" });
  assert.deepEqual(parsePromotionFile("values.prd.us1.yaml"), { environment: "production", region: "us1" });
  // Apps pinned to the central clusters spell the same two environments cst/cpr.
  assert.equal(parsePromotionFile("values.cst.eu1.yaml").environment, "staging");
  assert.equal(parsePromotionFile("values.cpr.eu1.yaml").environment, "production");
});

test("values.yaml and anything unrecognised is not a promotion", () => {
  // values.yaml carries a `stableVersion: 0.0.0` placeholder; rejecting it keeps version zero out.
  for (const name of ["values.yaml", "values.dev.eu1.yaml", "values.stg..yaml", "values.stg.eu1.yaml.bak", "Chart.yaml", "values.stg.eu1.extra.yaml"]) {
    assert.equal(parsePromotionFile(name), null, name);
  }
});

test("stableVersion is read only from column 0, quotes stripped", () => {
  assert.equal(stableVersion("a: 1\nstableVersion: 1.2.3\n"), "1.2.3");
  assert.equal(stableVersion('stableVersion: "1.2.3"'), "1.2.3");
  assert.equal(stableVersion("stableVersion: '1.2.3'   # bumped by kargo"), "1.2.3");
  assert.equal(stableVersion("# stableVersion: 9.9.9\n  stableVersion: 8.8.8\nsub:\n  stableVersion: 7.7.7"), null);
  assert.equal(stableVersion("stableVersion:\n"), null);
  assert.equal(stableVersion("stableVersion: ''"), null);
});

const promoted = (environment, region, version) => ({ file: { environment, region }, version });

test("collapse: staging first, versions deduplicated, empty environments left out", () => {
  const out = collapse([promoted("production", "eu", "1.0.0"), promoted("staging", "eu", "1.1.0"), promoted("staging", "us", "1.1.0")]);
  assert.deepEqual(out.map((e) => [e.environment, e.versions]), [["staging", ["1.1.0"]], ["production", ["1.0.0"]]]);
  assert.deepEqual(collapse([promoted("production", "eu", "1.0.0")]).map((e) => e.environment), ["production"]);
  assert.deepEqual(collapse([]), []);
});

test("the displayed version is the lowest, ordered numerically, and regions may disagree", () => {
  const [staging] = collapse([promoted("staging", "eu", "1.10.0"), promoted("staging", "us", "1.9.0")]);
  assert.equal(staging.displayVersion, "1.9.0"); // as strings, 1.10.0 would sort below
  assert.equal(staging.regionsAgree, false);
  assert.equal(collapse([promoted("staging", "eu", "2.0.0")])[0].regionsAgree, true);
});

test("version helpers: v prefix and numeric comparison", () => {
  assert.equal(stripVersion("v1.2.3"), "1.2.3");
  assert.equal(stripVersion("lec-app@1.2.3"), "lec-app@1.2.3");
  assert.equal(isNewer("1.10.0", "1.9.0"), true);
  assert.equal(isNewer("1.1", "1.1.0"), false);
  assert.equal(isNewer("latest", "1.0.0"), false); // a non-numeric tag must not pose as an upgrade
});

test("image names come from a CircleCI config, nested, deduplicated, unquoted", () => {
  const config = `jobs:\n  build:\n    steps:\n      - build:\n          repository: "lec-ai-chat"\n      - push:\n          repository: lec-ai-chat\n          repository: other-image   # trailing\n  x:\n    repositoryName: not-this`;
  assert.deepEqual(imageNames(config), ["lec-ai-chat", "other-image"]);
  assert.deepEqual(imageNames("no images here"), []);
});

test("a YAML alias is resolved to the anchor it names (beyond the macOS app, which reads it literally)", () => {
  const config = [
    "x-repository-name: &repositoryName lec-scanningconfig",
    "jobs:",
    "  a:",
    "    repository: *repositoryName",
    "  b:",
    "    repository: *repositoryName",
    "  c:",
    "    repository: *unknown",
  ].join("\n");
  // Deduplicated; an alias with no anchor is dropped rather than searched for as "*unknown".
  assert.deepEqual(imageNames(config), ["lec-scanningconfig"]);
});

test("a values file must declare the image, not merely mention it", () => {
  assert.equal(declaresImage("lec-ai-chat", "appName: lec-ai-chat\n"), true);
  assert.equal(declaresImage("lec-ai-chat", "image:\n  repositoryName: 'lec-ai-chat'\n"), true);
  assert.equal(declaresImage("lec-ai-chat", "- imageTag: registry.example.com/team/lec-ai-chat\n"), true);
  // The real false positive: a substring inside an unrelated secret name.
  assert.equal(declaresImage("lec-ai-chat", "secretName: clickhouseuser-ch-lec-ai-chat-credentials\n"), false);
  assert.equal(declaresImage("lec-ai-chat", "unrelatedKey: lec-ai-chat\n"), false);
});

test("a decommissioned folder, with no Kargo subscription, is not promoted into", () => {
  assert.equal(isKargoManaged([{ name: "kargo", oid: "1" }, { name: "values.stg.eu.yaml", oid: "2" }]), true);
  assert.equal(isKargoManaged([{ name: "values.stg.eu.yaml", oid: "2" }]), false);
});

test("search hits become app folders: rendered copies dropped, one per folder", () => {
  const hits = [
    { repo: "o/deploy", path: "chat/values.yaml" },
    { repo: "o/deploy", path: "chat/kargo/values.yaml" },
    { repo: "o/deploy", path: ".stages/eu/chat/values.yaml" },
    { repo: "o/deploy", path: "values.yaml" },
    { repo: "o/deploy", path: "other/values.yaml" },
  ];
  assert.deepEqual(locationsFromSearchPaths(hits), [
    { deploymentsRepo: "o/deploy", appPath: "chat" },
    { deploymentsRepo: "o/deploy", appPath: "other" },
  ]);
});
