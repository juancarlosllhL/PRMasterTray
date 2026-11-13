import { test } from "node:test";
import assert from "node:assert/strict";
import { withEnvFallback } from "../src/core/secretsEnv.js";

const store = (initial = {}) => ({
  available: () => true,
  has: (name) => name in initial,
  get: (name) => initial[name] ?? null,
  set: (name, value) => { initial[name] = value; },
  delete: (name) => { delete initial[name]; },
});

test("the environment variable stands in when nothing is stored", () => {
  const secrets = withEnvFallback(store(), { OPENROUTER_API_KEY: "from-env" });
  assert.equal(secrets.has("openrouter-key"), true);
  assert.equal(secrets.get("openrouter-key"), "from-env");
});

test("a key saved in Settings wins over the environment", () => {
  const secrets = withEnvFallback(store({ "openrouter-key": "saved" }), { OPENROUTER_API_KEY: "from-env" });
  assert.equal(secrets.get("openrouter-key"), "saved");
});

test("an empty or missing variable changes nothing", () => {
  assert.equal(withEnvFallback(store(), { OPENROUTER_API_KEY: "  " }).has("openrouter-key"), false);
  assert.equal(withEnvFallback(store(), {}).get("openrouter-key"), null);
});

test("other secrets never read the environment", () => {
  const secrets = withEnvFallback(store(), { OPENROUTER_API_KEY: "from-env" });
  assert.equal(secrets.has("jira-token"), false);
  assert.equal(secrets.get("jira-token"), null);
});

test("writing still goes to the store", () => {
  const secrets = withEnvFallback(store(), {});
  secrets.set("openrouter-key", "typed");
  assert.equal(secrets.get("openrouter-key"), "typed");
});
