// The user's preferences: a small validated key-value store. Persistence is
// injected (`read` returns the stored text or null, `write` stores it) so the
// rules can be tested without a disk.
//
// A value outside what a setting allows falls back to its default rather than
// breaking the app, so a hand-edited or downgraded file cannot do harm — and the
// review window in particular can never be switched off by a stray value.

import { parseEndpoint } from "./score.js";

const oneOf = (...allowed) => (v) => allowed.includes(v);
const endpointOk = (v) => {
  try {
    parseEndpoint(v);
    return v.trim() !== "";
  } catch {
    return false;
  }
};
const positiveInt = (v) => Number.isInteger(v) && v > 0;
const stringList = (v) => Array.isArray(v) && v.every((x) => typeof x === "string");

// Each setting: its default and what makes a value acceptable.
const SPEC = {
  // Writes to GitHub: off until the user turns it on.
  autoUpdateBranches: { default: false, valid: (v) => typeof v === "boolean" },
  // null = off.
  staleDays: { default: 30, valid: oneOf(null, 14, 30, 90, 180) },
  mergedWindowDays: { default: 1, valid: oneOf(null, 1, 3, 7) },
  // No "off" here: see the note above.
  reviewWindowDays: { default: 14, valid: oneOf(7, 14, 30) },
  // How far back the Board's Done column reaches; null = off.
  jiraWindowDays: { default: 14, valid: oneOf(null, 7, 14, 30) },
  boardLayout: { default: "list", valid: oneOf("list", "board") },
  // An allowlist, unlike teams: an organization has many boards and only yours belong here. By node id.
  projectSelection: { default: [], valid: stringList },
  // The last good list of boards, so a failed discovery falls back to it.
  knownProjects: { default: [], valid: (v) => Array.isArray(v) && v.every((p) => p && typeof p.id === "string" && typeof p.title === "string" && Array.isArray(p.options)) },
  // Project id -> option id -> where that Status option lands ("hidden" or a lane).
  projectLaneMap: { default: {}, valid: (v) => v && typeof v === "object" && !Array.isArray(v) && Object.values(v).every((m) => m && typeof m === "object" && Object.values(m).every((c) => ["hidden", "toDo", "inProgress", "reviewing", "testing", "done"].includes(c))) },
  hiddenOrganizations: { default: [], valid: stringList },
  showPrivateRepositories: { default: true, valid: (v) => typeof v === "boolean" },
  // Teams whose review requests are not listed, by combinedSlug.
  disabledTeams: { default: [], valid: stringList },
  theme: { default: "system", valid: oneOf("system", "light", "dark") },
  diffLayout: { default: "unified", valid: oneOf("unified", "split") },
  diffFontFamily: { default: null, valid: (v) => v === null || (typeof v === "string" && v.length > 0) },
  diffFontSize: { default: 12, valid: (v) => positiveInt(v) && v >= 8 && v <= 32 },
  diffLigatures: { default: false, valid: (v) => typeof v === "boolean" },
  // Patterns per section, in settings order; null means the built-in lists.
  diffSectionPatterns: { default: null, valid: (v) => v === null || (typeof v === "object" && !Array.isArray(v) && Object.values(v).every(stringList)) },
  honoursGitAttributes: { default: true, valid: (v) => typeof v === "boolean" },
  approvalQuips: { default: false, valid: (v) => typeof v === "boolean" },
  hideTitleEmoji: { default: false, valid: (v) => typeof v === "boolean" },
  launchAtLogin: { default: false, valid: (v) => typeof v === "boolean" },
  heatmapEnabled: { default: true, valid: (v) => typeof v === "boolean" },
  // Where Score sends changed lines; null means OpenRouter itself.
  heatmapBaseURL: { default: null, valid: (v) => v === null || (typeof v === "string" && endpointOk(v)) },
  lastSeenVersion: { default: null, valid: (v) => v === null || typeof v === "string" },
};

export const DEFAULTS = Object.freeze(Object.fromEntries(Object.entries(SPEC).map(([k, s]) => [k, s.default])));

const clean = (key, value) => {
  const spec = SPEC[key];
  // Lists of strings lose their non-string entries and duplicates instead of being thrown away whole.
  const candidate = spec.valid === stringList && Array.isArray(value) ? [...new Set(value.filter((x) => typeof x === "string"))] : value;
  return spec.valid(candidate) ? candidate : spec.default;
};

function parse(text) {
  try {
    const parsed = JSON.parse(text ?? "null");
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

export function createSettings({ read, write }) {
  const stored = parse(read());
  const values = Object.fromEntries(Object.keys(SPEC).map((key) => [key, structuredClone(key in stored ? clean(key, stored[key]) : SPEC[key].default)]));
  const listeners = new Set();

  return {
    get: (key) => {
      if (!(key in SPEC)) throw new Error(`unknown setting: ${key}`);
      // A copy: handing out the stored object would let a caller change a setting without going through `set`.
      return structuredClone(values[key]);
    },
    all: () => structuredClone(values),
    set(key, value) {
      if (!(key in SPEC)) throw new Error(`unknown setting: ${key}`);
      if (!SPEC[key].valid(value)) throw new Error(`invalid value for ${key}: ${JSON.stringify(value)}`);
      if (JSON.stringify(values[key]) === JSON.stringify(value)) return;
      values[key] = structuredClone(value);
      write(JSON.stringify(values));
      for (const listener of listeners) listener(key, values[key]);
    },
    onChange(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}
