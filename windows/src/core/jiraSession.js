// Signing in to Jira, and remembering it. `store` is the encrypted secret store
// (get / set / delete by name); the API token goes nowhere else: not preferences,
// not a log, not a fixture.
import { JiraError, createCredentials, createJiraClient } from "./jiraApi.js";

const NAME = "jira";

// Nothing is stored until it has been tested, so a typo is refused where it was
// typed rather than an hour later as a failed refresh. A rejection blames the
// email and token together, because Jira answers a bad token, a wrong email and
// outright nonsense identically, and naming one would be a guess.
export async function signInToJira({ input, store, fetchImpl = fetch }) {
  const credentials = createCredentials(input);
  let name;
  try {
    name = await createJiraClient({ credentials, fetchImpl }).verify();
  } catch (e) {
    if (e instanceof JiraError && e.code === "unauthorized") {
      throw new JiraError("unauthorized", "Jira didn't accept that email and API token together. Check both, and create a token at id.atlassian.com under Security.");
    }
    throw e;
  }
  store.set(NAME, JSON.stringify({ baseURL: credentials.baseURL, email: credentials.email, apiToken: input.apiToken.trim() }));
  return { name, baseURL: credentials.baseURL, email: credentials.email };
}

// null when nobody is signed in, or what was saved cannot be used.
export function restoreJira({ store }) {
  const raw = store.get(NAME);
  if (!raw) return null;
  try {
    return createCredentials(JSON.parse(raw));
  } catch {
    return null;
  }
}

export function signOutOfJira({ store }) {
  store.delete(NAME);
}
