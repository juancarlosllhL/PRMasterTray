import { test } from "node:test";
import assert from "node:assert/strict";
import { restoreJira, signInToJira, signOutOfJira } from "../src/core/jiraSession.js";

function vault() {
  const data = new Map();
  return { data, get: (k) => data.get(k) ?? null, set: (k, v) => data.set(k, v), delete: (k) => data.delete(k), has: (k) => data.has(k) };
}
const answer = (status, json = {}) => async () => ({ ok: status === 200, status, json: async () => json });
const input = { baseURL: "https://acme.atlassian.net/", email: "me@acme.com", apiToken: "tok" };

test("nothing is stored until it has been tested: a typo is refused where it was typed", async () => {
  const store = vault();
  await assert.rejects(signInToJira({ input, store, fetchImpl: answer(401) }), /email and API token together/);
  assert.equal(store.has("jira"), false);
});

test("a rejection blames the email and token together: Jira answers a bad token, a wrong email and nonsense identically", async () => {
  for (const status of [401, 403]) {
    await assert.rejects(signInToJira({ input, store: vault(), fetchImpl: answer(status) }), (e) => /together/.test(e.message) && /id\.atlassian\.com/.test(e.message));
  }
});

test("success names who it signed in as, and only then is the sign-in kept", async () => {
  const store = vault();
  const out = await signInToJira({ input, store, fetchImpl: answer(200, { displayName: "Ada Lovelace" }) });
  assert.deepEqual([out.name, out.baseURL, out.email], ["Ada Lovelace", "https://acme.atlassian.net", "me@acme.com"]);
  assert.deepEqual(JSON.parse(store.get("jira")), { baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" });
});

test("bad input is refused before anything leaves the machine", async () => {
  let calls = 0;
  const fetchImpl = async () => { calls++; return answer(200)(); };
  await assert.rejects(signInToJira({ input: { ...input, baseURL: "http://insecure.example" }, store: vault(), fetchImpl }), /https:\/\//);
  await assert.rejects(signInToJira({ input: { ...input, email: "nope" }, store: vault(), fetchImpl }), /email/);
  assert.equal(calls, 0);
});

test("other failures keep their own words: a network error is not a bad password", async () => {
  await assert.rejects(signInToJira({ input, store: vault(), fetchImpl: async () => { throw new Error("getaddrinfo ENOTFOUND"); } }), /could not be reached/);
  await assert.rejects(signInToJira({ input, store: vault(), fetchImpl: answer(500) }), /HTTP 500/);
});

test("restoring picks the saved sign-in up at launch; a damaged one is as good as none", () => {
  const store = vault();
  assert.equal(restoreJira({ store }), null);
  store.set("jira", JSON.stringify({ baseURL: "https://acme.atlassian.net", email: "me@acme.com", apiToken: "tok" }));
  assert.equal(restoreJira({ store }).baseURL, "https://acme.atlassian.net");
  store.set("jira", "{not json");
  assert.equal(restoreJira({ store }), null);
  store.set("jira", JSON.stringify({ baseURL: "http://insecure", email: "x@y", apiToken: "t" }));
  assert.equal(restoreJira({ store }), null);
});

test("signing out removes the token", () => {
  const store = vault();
  store.set("jira", "x");
  signOutOfJira({ store });
  assert.equal(store.has("jira"), false);
});
