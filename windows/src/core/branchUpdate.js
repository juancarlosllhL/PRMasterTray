// Which pull requests to bring up to date with their base branch.
//
// The set of already-attempted keys *is* the state. The key is (id, head oid):
// a refused update — conflict, protected branch, lost race — leaves the head
// where it was, so the key stays and the app never asks again; a successful one
// moves the head and retires the old key. Keying on id alone would retry a
// doomed update every poll; keying on nothing would push a commit a minute.
//
// Call only with a *successful* refresh: this writes to GitHub.
const key = (pr) => `${pr.id}@${pr.headRefOid}`;

export function decideBranchUpdates(prs, attempted) {
  // "behind" is already the narrow set: readiness ranks draft, conflicts and
  // checks above merge state, so a PR is only behind once otherwise fine.
  const behind = prs.filter((p) => p.readiness === "behind");
  return {
    update: behind.filter((p) => !attempted.has(key(p))),
    attempted: new Set(behind.map(key)),
  };
}
