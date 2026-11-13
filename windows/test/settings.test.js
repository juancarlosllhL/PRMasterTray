import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULTS, createSettings } from "../src/core/settings.js";
import { PullRequestFilter } from "../src/core/filter.js";

function memory(initial = null) {
  const box = { text: initial, writes: 0 };
  return { box, read: () => box.text, write: (t) => { box.text = t; box.writes++; } };
}

test("with nothing stored, every setting has its default", () => {
  const settings = createSettings(memory());
  assert.deepEqual(settings.all(), DEFAULTS);
  assert.equal(settings.get("diffLayout"), "unified");
  assert.equal(settings.get("staleDays"), 30);
});

test("the defaults are the macOS app's: nothing hidden, auto-update off here, windows on their usual spans", () => {
  assert.deepEqual([DEFAULTS.hiddenOrganizations, DEFAULTS.showPrivateRepositories], [[], true]);
  assert.deepEqual([DEFAULTS.mergedWindowDays, DEFAULTS.reviewWindowDays, DEFAULTS.staleDays], [1, 14, 30]);
  assert.equal(DEFAULTS.autoUpdateBranches, false); // opt-in on this port: it pushes into your branches
});

test("a change is persisted at once and survives a restart", () => {
  const store = memory();
  createSettings(store).set("diffLayout", "split");
  assert.equal(createSettings(store).get("diffLayout"), "split");
  assert.equal(store.box.writes, 1);
});

test("an unchanged value writes nothing", () => {
  const store = memory();
  const settings = createSettings(store);
  settings.set("diffLayout", "unified");
  assert.equal(store.box.writes, 0);
});

test("a value outside what a setting allows falls back to its default rather than breaking the app", () => {
  const settings = createSettings(memory(JSON.stringify({ diffLayout: "sideways", staleDays: 7, mergedWindowDays: 99, reviewWindowDays: "soon", diffFontSize: -3, theme: 5 })));
  assert.deepEqual(
    [settings.get("diffLayout"), settings.get("staleDays"), settings.get("mergedWindowDays"), settings.get("reviewWindowDays"), settings.get("diffFontSize"), settings.get("theme")],
    ["unified", 30, 1, 14, DEFAULTS.diffFontSize, "system"],
  );
});

test("off is a real choice for the windows that have one, and null survives a round trip", () => {
  const store = memory();
  const settings = createSettings(store);
  settings.set("staleDays", null);
  settings.set("mergedWindowDays", null);
  assert.deepEqual([createSettings(store).get("staleDays"), createSettings(store).get("mergedWindowDays")], [null, null]);
});

test("the review window can never be switched off by a stray value: an unrecognised one means the default", () => {
  const settings = createSettings(memory(JSON.stringify({ reviewWindowDays: 0 })));
  assert.equal(settings.get("reviewWindowDays"), 14);
});

test("a setting this app does not know is refused, not stored", () => {
  const settings = createSettings(memory());
  assert.throws(() => settings.set("nonsense", 1), /unknown setting/i);
  assert.throws(() => settings.set("diffLayout", "sideways"), /invalid/i);
});

test("a corrupt settings file means defaults, not a crash", () => {
  assert.deepEqual(createSettings(memory("{not json")).all(), DEFAULTS);
  assert.deepEqual(createSettings(memory("[1,2]")).all(), DEFAULTS);
});

test("list settings keep only strings, once each", () => {
  const settings = createSettings(memory(JSON.stringify({ hiddenOrganizations: ["a", "a", 3, null, "b"], disabledTeams: "x" })));
  assert.deepEqual(settings.get("hiddenOrganizations"), ["a", "b"]);
  assert.deepEqual(settings.get("disabledTeams"), []);
});

test("listeners hear about a change, with the key", () => {
  const settings = createSettings(memory());
  const heard = [];
  settings.onChange((key, value) => heard.push([key, value]));
  settings.set("showPrivateRepositories", false);
  settings.set("showPrivateRepositories", false); // unchanged: not announced twice
  assert.deepEqual(heard, [["showPrivateRepositories", false]]);
});

// ---- The filter -------------------------------------------------------------

const item = (organization, isPrivate = false) => ({ organization, isPrivate });

test("the default filter hides nothing", () => {
  const filter = new PullRequestFilter();
  assert.equal(filter.isActive, false);
  assert.deepEqual(filter.apply([item("a"), item("b", true)]).length, 2);
});

test("private repositories and hidden organizations are dropped, keeping the fetch's order", () => {
  const filter = new PullRequestFilter({ hiddenOrganizations: ["noisy"], showPrivateRepositories: false });
  const kept = filter.apply([item("a"), item("noisy"), item("b", true), item("c")]);
  assert.deepEqual(kept.map((i) => i.organization), ["a", "c"]);
  assert.equal(filter.isActive, true);
});

test("organizations are a blocklist: a new one is visible until the user names it", () => {
  const filter = new PullRequestFilter({ hiddenOrganizations: ["old"] });
  assert.equal(filter.includes(item("brand-new")), true);
  assert.equal(filter.shows("old"), false);
});

test("the repository's organization is the part before the slash", () => {
  assert.equal(PullRequestFilter.organizationOf("Lansweeper/LECScanningConfig"), "Lansweeper");
});

test("the filter reads the organization from the repository when the item has none", () => {
  const filter = new PullRequestFilter({ hiddenOrganizations: ["noisy"] });
  assert.equal(filter.includes({ repo: "noisy/app", isPrivate: false }), false);
  assert.equal(filter.includes({ repo: "fine/app", isPrivate: false }), true);
});

test("the Score proxy URL follows the endpoint rules: https, or plain http only to localhost", () => {
  const settings = createSettings(memory());
  settings.set("heatmapBaseURL", "https://proxy.example/api/v1");
  settings.set("heatmapBaseURL", "http://localhost:8080/v1");
  assert.throws(() => settings.set("heatmapBaseURL", "http://proxy.example/v1"), /invalid/i);
  assert.throws(() => settings.set("heatmapBaseURL", "https://user:pw@proxy.example/v1"), /invalid/i);
  settings.set("heatmapBaseURL", null);
  assert.equal(settings.get("heatmapBaseURL"), null);
});

test("the Board's settings: Done window, layout, chosen boards, known boards and the column choices", () => {
  const settings = createSettings(memory());
  assert.deepEqual([settings.get("jiraWindowDays"), settings.get("boardLayout"), settings.get("projectSelection"), settings.get("knownProjects"), settings.get("projectLaneMap")], [14, "list", [], [], {}]);
  settings.set("jiraWindowDays", null);
  settings.set("boardLayout", "board");
  settings.set("projectSelection", ["P1"]);
  settings.set("knownProjects", [{ id: "P1", title: "Roadmap", number: 1, owner: "acme", url: "https://x", statusFieldID: "F", options: [{ id: "o", name: "Todo" }] }]);
  settings.set("projectLaneMap", { P1: { o: "done", "": "toDo" } });
  assert.throws(() => settings.set("jiraWindowDays", 3), /invalid/i);
  assert.throws(() => settings.set("boardLayout", "grid"), /invalid/i);
  assert.throws(() => settings.set("projectLaneMap", { P1: { o: "sideways" } }), /invalid/i);
  assert.throws(() => settings.set("knownProjects", [{ title: "no id" }]), /invalid/i);
});

test("known boards survive a restart: only lists of strings are cleaned on load", () => {
  const store = memory();
  const boards = [{ id: "P1", title: "Roadmap", number: 1, owner: "acme", url: "https://x", statusFieldID: "F", options: [{ id: "o", name: "Todo" }] }];
  createSettings(store).set("knownProjects", boards);
  assert.deepEqual(createSettings(store).get("knownProjects"), boards);
});

test("a value read from settings is a copy: changing it changes nothing, here or in any other instance", () => {
  const a = createSettings(memory());
  a.get("projectLaneMap").P1 = { o: "done" };
  a.get("hiddenOrganizations").push("oops");
  assert.deepEqual(a.get("projectLaneMap"), {});
  assert.deepEqual(a.get("hiddenOrganizations"), []);
  const b = createSettings(memory());
  assert.deepEqual([b.get("projectLaneMap"), b.get("hiddenOrganizations")], [{}, []]);
  assert.deepEqual(DEFAULTS.projectLaneMap, {});
});
