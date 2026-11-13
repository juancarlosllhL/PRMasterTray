function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text; // textContent: titles come from the network
  return node;
}

const div = (className, text) => el("div", className, text);

// One clickable row; clicking opens `url`.
function makeRow(className, { title, repo, number, status, url, prURL, chips = [] }) {
  const row = div(`row ${className}`);
  row.append(div("title", title), div("repo", `${repo} #${number}`), div("status", status));
  if (chips.length > 0) {
    const bar = div("chips");
    for (const c of chips) bar.append(div(`chip chip-${c.kind}`, c.label));
    row.append(bar);
  }
  row.addEventListener("click", () => window.prmaster.open(url));
  // Copy Link and Copy ID are on the right-click menu of every pull request.
  row.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    window.prmaster.contextMenu({ kind: "pr", url: prURL ?? url, copyID: `${repo}#${number}` });
  });
  return row;
}

// Buttons on a row. A ready pull request of yours is merged from its row, so
// Merge takes Review's place there; everything else is read first.
function addButton(row, label, hint, onClick) {
  const button = document.createElement("button");
  button.textContent = label;
  button.title = hint;
  button.addEventListener("click", (event) => {
    event.stopPropagation(); // the row itself opens the pull request
    onClick();
  });
  row.append(button);
}

function addOwnActions(row, r) {
  if (r.readiness === "ready") addButton(row, "Merge", "Squash and merge", () => window.prmaster.act("merge", r.id));
  else addButton(row, "Review", "Read the diff", () => window.prmaster.review("own", r.id));
  if (r.stale) addButton(row, "Close", `Open for ${r.age}`, () => window.prmaster.act("close", r.id));
}

// An offer to update, with Install when this build can (an unpackaged run cannot replace itself).
function renderUpdate(update) {
  const bar = document.getElementById("update");
  bar.hidden = !update.version;
  bar.replaceChildren();
  if (!update.version) return;
  bar.append(el("span", "", update.installing ? `Installing PR Master ${update.version}…` : `PR Master ${update.version} is available.${update.failure ? ` Last try failed: ${update.failure}` : ""}`));
  if (update.canInstall && !update.installing) {
    const install = Object.assign(el("button", "primary"), { textContent: "Install" });
    install.addEventListener("click", () => window.prmaster.installUpdate());
    bar.append(install);
  }
}

function render({ rows, shipments, reviews, reviewError, error, loaded, update }) {
  renderUpdate(update);
  const ready = rows.filter((r) => r.readiness === "ready").length;
  document.getElementById("title").textContent = `PR Master — ${ready} ready of ${rows.length}`;

  const errorBox = document.getElementById("error");
  errorBox.hidden = !error;
  errorBox.textContent = error ?? "";

  const list = document.getElementById("list");
  list.replaceChildren();
  if (rows.length === 0 && !error) list.append(div("empty", loaded ? "No open pull requests." : "Loading…"));

  for (const r of rows) {
    const row = makeRow(r.readiness, { ...r, status: r.stale ? `${r.status} · open ${r.age}` : r.status });
    addOwnActions(row, r);
    list.append(row);
  }

  if (reviews.length > 0 || reviewError) {
    list.append(div("section", "Review requests"));
    if (reviewError) list.append(div("empty", `Unavailable: ${reviewError}`));
    for (const r of reviews) {
      const row = makeRow(`review-${r.state}`, { ...r, repo: r.repo, status: `${r.status} · ${r.author} · ${r.age}` });
      row.append(div("repo", `${r.teams} · ${r.size}`));
      addButton(row, "Review", "Read the diff", () => window.prmaster.review("review", r.id));
      list.append(row);
    }
  }

  if (shipments.length > 0) {
    list.append(div("section", "Recently merged"));
    for (const s of shipments) list.append(makeRow(`ship-${s.kind}`, { ...s, status: s.label }));
  }
}

document.getElementById("refresh").addEventListener("click", () => window.prmaster.refresh());
window.prmaster.onState(render);
window.prmaster.state().then(render);
