// The set of already-notified IDs *is* the state — no snapshot diff. A PR that
// became ready while the app was closed has no recorded ID, so it notifies on
// next launch without cold-start handling. Call only with a *successful*
// refresh: a failed fetch would look like everything vanishing at once.
export function decide(prs, notified) {
  const ready = prs.filter((p) => p.readiness === "ready");
  // Anything that stopped being ready drops out and is thereby re-armed.
  return {
    notify: ready.filter((p) => !notified.has(p.id)),
    updated: new Set(ready.map((p) => p.id)),
  };
}
