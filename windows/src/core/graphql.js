const ENDPOINT = "https://api.github.com/graphql";

export function assertNoErrors(body) {
  if (body.errors?.length) {
    throw new Error(body.errors.map((e) => e.message).join("; "));
  }
}

export async function post({ token, fetchImpl, query, variables }) {
  const res = await fetchImpl(ENDPOINT, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`GitHub responded ${res.status}`);
  return res.json();
}

// Errors first: GitHub reports an SSO failure as a 200 with a null payload,
// which would otherwise read as nothing anywhere.
export async function query(args) {
  const body = await post(args);
  assertNoErrors(body);
  return body.data;
}

// One document of aliased fields costs a rate limit of 1 whatever the alias
// count. Aliases and variable *names* are generated and every remote *value*
// rides as a variable, so nothing untrusted reaches the document text.
export const document = (declarations, fields) =>
  `query(${declarations.join(", ")}) {\n${fields.join("\n")}\n}`;

export const ownerOf = (repo) => repo.slice(0, repo.indexOf("/"));
export const nameOf = (repo) => repo.slice(repo.indexOf("/") + 1);

// REST GET, for the endpoints GraphQL does not offer (compare, pull files, code search).
export async function get({ token, fetchImpl, url }) {
  const res = await fetchImpl(url, { headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json" } });
  if (!res.ok) throw new Error(`GitHub responded ${res.status}`);
  return res.json();
}
