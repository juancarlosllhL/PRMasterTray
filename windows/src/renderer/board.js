// The Board tab: Jira issues and GitHub Project items on shared columns, as a list
// or as a board. Everything it shows is decided in the main process (see
// core/boardView.js); this only draws it, and sends back moves and menu requests.

const boardPane = document.getElementById("boardpane");
let boardState = null;
const expanded = new Set(); // card ids whose pull requests are open
let formValues = {};

const PRIORITY_SYMBOL = { Critical: "⏫", High: "🔼", Medium: "➖", Low: "🔽", Lowest: "⏬" };
const SOURCE_LABEL = { jira: "Jira", github: "GH" };

function linkSummary(card) {
  switch (card.linkState) {
    case "loading": return "Checking…";
    case "unknown": return "Couldn't check";
    case "none": return card.id.kind === "jira" || card.id.kind === "paired" ? "No PRs open" : "No PRs";
    case "linked": return `${card.links.length} PR${card.links.length === 1 ? "" : "s"}`;
    default: return null; // a pull request itself has nothing to look up
  }
}

function cardElement(card, showsPriority) {
  const el = div(`card${card.moving ? " moving" : ""}`);
  el.draggable = card.canMove;
  el.dataset.id = card.idString;

  const top = div("top");
  if (showsPriority && PRIORITY_SYMBOL[card.priority.name]) top.append(div("", PRIORITY_SYMBOL[card.priority.name]));
  top.append(div(`tint-${card.tint}`, card.typeName));
  top.append(div("ref", card.pairedReference ? `${card.reference} · ${card.pairedReference}` : card.reference));
  for (const s of card.sources) top.append(div("src", SOURCE_LABEL[s.kind]));
  el.append(top, div("title", card.title));
  const status = div("status-pill", card.moving ? `${card.statusName} →` : card.statusName);
  el.append(status);

  const summary = linkSummary(card);
  if (summary) {
    const open = expanded.has(card.idString);
    const toggle = div("links-toggle", `${card.links.length ? (open ? "▾" : "▸") : "•"} ${summary}`);
    if (card.links.length) {
      toggle.addEventListener("click", (e) => {
        e.stopPropagation();
        if (open) expanded.delete(card.idString);
        else expanded.add(card.idString);
        renderBoard();
      });
    }
    el.append(toggle);
    if (open) {
      const prs = div("prs");
      for (const link of card.links) {
        const row = div("pr");
        row.append(div(`state-${link.state.toLowerCase()}`, link.isDraft ? "draft" : link.state.toLowerCase()), div("", `${link.repo} #${link.number} ${link.title}`));
        row.addEventListener("click", (e) => {
          e.stopPropagation();
          window.prmaster.open(link.url);
        });
        row.addEventListener("contextmenu", (e) => {
          e.preventDefault();
          e.stopPropagation();
          window.prmaster.contextMenu({ kind: "pr", url: link.url, copyID: `${link.repo}#${link.number}` });
        });
        prs.append(row);
      }
      el.append(prs);
    }
  }

  el.addEventListener("click", () => card.openURL && window.prmaster.open(card.openURL));
  el.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    window.prmaster.contextMenu({ kind: "card", cardId: card.idString, url: card.openURL, copyID: card.copyID, canMove: card.canMove && !card.moving, lane: card.lane });
  });
  el.addEventListener("dragstart", (e) => {
    e.dataTransfer.setData("text/plain", card.idString);
    e.dataTransfer.effectAllowed = "move";
  });
  return el;
}

// A drop target: a column of the board, or a section of the list.
function makeDropTarget(el, lane) {
  el.addEventListener("dragover", (e) => {
    e.preventDefault();
    el.classList.add("dropping");
  });
  el.addEventListener("dragleave", () => el.classList.remove("dropping"));
  el.addEventListener("drop", (e) => {
    e.preventDefault();
    el.classList.remove("dropping");
    window.prmaster.board.move(e.dataTransfer.getData("text/plain"), lane);
  });
}

function laneElement(column) {
  const lane = div("lane");
  lane.append(div("lane-heading", `${column.title} · ${column.cards.length}`));
  for (const card of column.cards) lane.append(cardElement(card, column.showsPriority));
  makeDropTarget(lane, column.lane);
  return lane;
}

// ---- The form a Jira step can open ------------------------------------------

function fieldProblem(field, value) {
  const trimmed = value.trim();
  if (field.kind.type === "option") return field.kind.allowed.includes(trimmed) ? null : `Choose a ${field.name}.`;
  const body = field.addedPrefix && trimmed.toLowerCase().startsWith(field.addedPrefix.toLowerCase()) ? trimmed.slice(field.addedPrefix.length) : trimmed;
  return body.trim() ? null : `${field.name} is required.`;
}

function formElement(request) {
  const form = div("form");
  form.append(el("h3", "", `Moving ${request.key}: ${request.from} → ${request.to}`));
  const problems = {};
  for (const field of request.fields) {
    const label = el("label");
    label.append(el("span", "", field.name));
    let control;
    if (field.kind.type === "option") {
      control = el("select");
      control.append(Object.assign(el("option"), { value: "", textContent: "Choose…" }), ...field.kind.allowed.map((v) => Object.assign(el("option"), { value: v, textContent: v })));
    } else if (field.kind.type === "richText") {
      control = el("textarea");
      control.rows = 3;
    } else {
      control = el("input");
    }
    control.value = formValues[field.id] ?? "";
    control.addEventListener("input", () => (formValues[field.id] = control.value));
    label.append(control);
    if (field.addedPrefix) label.append(el("span", "", `Starts with ${field.addedPrefix} automatically`));
    const problem = div("problem");
    problems[field.id] = problem;
    label.append(problem);
    form.append(label);
  }
  const actions = div("actions");
  const go = Object.assign(el("button", "primary"), { textContent: "Move" });
  go.addEventListener("click", () => {
    let ok = true;
    for (const field of request.fields) {
      const message = fieldProblem(field, formValues[field.id] ?? "");
      problems[field.id].textContent = message ?? "";
      if (message) ok = false;
    }
    if (!ok) return;
    window.prmaster.board.fields(formValues);
    formValues = {};
  });
  const cancel = Object.assign(el("button"), { textContent: "Cancel" });
  cancel.addEventListener("click", () => {
    window.prmaster.board.fields(null);
    formValues = {};
  });
  actions.append(go, cancel);
  form.append(actions);
  return form;
}

// ---- The pane ---------------------------------------------------------------

function banner(text, bad, dismiss) {
  const b = div(`banner${bad ? " bad" : ""}`);
  b.append(el("span", "", text));
  if (dismiss) {
    const x = Object.assign(el("button"), { textContent: "Dismiss" });
    x.addEventListener("click", dismiss);
    b.append(x);
  }
  return b;
}

const PANE_MESSAGES = { loading: "Loading…", empty: "Nothing assigned to you.", emptyByFilter: "Nothing matches the search." };

function renderBoard() {
  const state = boardState;
  if (!state) return;
  // The search box is kept as it is while typing: replacing it would drop focus.
  const typing = document.activeElement?.id === "boardSearch";
  const query = typing ? document.activeElement.value : state.query;

  const nodes = [];
  const bar = div("toolbar");
  const search = el("input");
  search.id = "boardSearch";
  search.placeholder = "Filter cards";
  search.value = query;
  search.addEventListener("input", () => window.prmaster.board.setQuery(search.value));
  const layout = el("select");
  layout.append(Object.assign(el("option"), { value: "list", textContent: "List" }), Object.assign(el("option"), { value: "board", textContent: "Board" }));
  layout.value = state.layout;
  layout.addEventListener("change", () => window.prmaster.board.setLayout(layout.value));
  bar.append(search, layout);
  nodes.push(bar);

  for (const line of state.moveFailures) nodes.push(banner(line, true, () => window.prmaster.board.dismiss()));
  for (const line of state.sourceFailures) nodes.push(banner(`${line} The list below may be out of date.`, false));
  if (state.fieldRequest) nodes.push(formElement(state.fieldRequest));

  if (!state.isConfigured) {
    const setup = div("empty", "Sign in to Jira or switch on a GitHub project to see your work here. ");
    const open = Object.assign(el("button"), { textContent: "Open Settings" });
    open.addEventListener("click", () => window.prmaster.openSettings());
    setup.append(open);
    nodes.push(setup);
  } else if (state.paneState === "failed") {
    nodes.push(banner(state.failureLines.join("  "), true));
  } else if (PANE_MESSAGES[state.paneState] && state.visibleCount === 0) {
    nodes.push(div("empty", PANE_MESSAGES[state.paneState]));
  } else if (state.layout === "board") {
    const columns = div("board-columns");
    for (const column of state.columns) columns.append(laneElement(column));
    nodes.push(columns);
  } else {
    for (const column of state.columns.filter((c) => c.cards.length > 0)) nodes.push(laneElement(column));
  }

  boardPane.replaceChildren(...nodes);
  if (typing) {
    const again = document.getElementById("boardSearch");
    again.focus();
    again.setSelectionRange(again.value.length, again.value.length);
  }
  const badge = document.getElementById("boardBadge");
  badge.hidden = state.cardCount === 0;
  badge.textContent = state.cardCount;
  window.prmaster.setWide?.(!boardPane.hidden && state.layout === "board");
}

window.prmaster.board.onState((state) => {
  boardState = state;
  renderBoard();
});
window.prmaster.board.state().then((state) => {
  boardState = state;
  renderBoard();
});

// ---- Tabs ---------------------------------------------------------------------

function showTab(name) {
  const board = name === "board";
  document.getElementById("prs").hidden = board;
  boardPane.hidden = !board;
  document.getElementById("tab-prs").classList.toggle("active", !board);
  document.getElementById("tab-board").classList.toggle("active", board);
  renderBoard();
}
document.getElementById("tab-prs").addEventListener("click", () => showTab("prs"));
document.getElementById("tab-board").addEventListener("click", () => showTab("board"));
document.getElementById("settings").addEventListener("click", () => window.prmaster.openSettings());
document.addEventListener("keydown", (e) => {
  if (e.ctrlKey && e.key === "1") showTab("prs");
  if (e.ctrlKey && e.key === "2") showTab("board");
});
