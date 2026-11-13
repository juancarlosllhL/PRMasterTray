const $ = (id) => document.getElementById(id);

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text; // textContent: paths and code come from the network
  return node;
}

const OMITTED = {
  tooLarge: "GitHub left this file's changes out because it is too large.",
  noTextChanges: "No text changes: binary, empty, mode-only or a pure rename.",
  unparseable: "This file's patch could not be read.",
};

const BANNERS = {
  headMoved: ["Somebody pushed while this was open. Merge and Approve are off until you reload.", true],
  closed: ["This pull request was merged or closed elsewhere.", true],
  loading: ["Loading…", false],
};

// ---- Description: GitHub's own rendering, trimmed to a short allow-list ----------
// GitHub already sanitises it; this is a second pair of hands, and the page's CSP
// (no inline script) is a third.

const ALLOWED_TAGS = new Set(["a", "p", "br", "hr", "strong", "b", "em", "i", "del", "code", "pre", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "thead", "tbody", "tr", "th", "td", "img", "details", "summary", "span", "div", "sub", "sup"]);
const ALLOWED_ATTRS = { a: ["href", "title"], img: ["src", "alt", "title", "width", "height"] };

function sanitise(html) {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const clean = (node) => {
    for (const child of [...node.childNodes]) {
      if (child.nodeType === Node.TEXT_NODE) continue;
      if (child.nodeType !== Node.ELEMENT_NODE || !ALLOWED_TAGS.has(child.tagName.toLowerCase())) {
        child.remove();
        continue;
      }
      const tag = child.tagName.toLowerCase();
      for (const attr of [...child.attributes]) {
        const allowed = ALLOWED_ATTRS[tag]?.includes(attr.name);
        const isUrl = attr.name === "href" || attr.name === "src";
        if (!allowed || (isUrl && !/^https:\/\//i.test(attr.value))) child.removeAttribute(attr.name);
      }
      clean(child);
    }
  };
  clean(doc.body);
  return doc.body;
}

function renderDescription(html) {
  $("description").hidden = !html;
  const body = $("descriptionBody");
  body.replaceChildren();
  if (!html) return;
  const clean = sanitise(html);
  body.append(...clean.childNodes);
  for (const a of body.querySelectorAll("a[href]")) {
    a.addEventListener("click", (e) => {
      e.preventDefault();
      window.diffApi.openLink(a.href);
    });
  }
}

// ---- Code cells ------------------------------------------------------------------

function styleOf(span) {
  const css = [];
  if (span.colour) css.push(`color:${span.colour}`);
  if (span.bold) css.push("font-weight:600");
  if (span.italic) css.push("font-style:italic");
  if (span.underline) css.push("text-decoration:underline");
  return css.join(";");
}

// Pieces of a line, cut wherever a syntax span or a find match starts or ends.
function pieces(line, matches, current) {
  const spans = line.spans ?? [{ text: line.text }];
  if (matches.length === 0) return spans.map((s) => ({ text: s.text, style: styleOf(s), mark: null }));
  const out = [];
  let offset = 0;
  for (const span of spans) {
    let start = 0;
    while (start < span.text.length) {
      const at = offset + start;
      const hit = matches.find((m) => at >= m.start && at < m.end);
      const nextCut = hit ? hit.end : (matches.map((m) => m.start).filter((s) => s > at).sort((a, b) => a - b)[0] ?? Infinity);
      const end = Math.min(span.text.length, nextCut - offset);
      out.push({ text: span.text.slice(start, end), style: styleOf(span), mark: hit ? (hit === current ? "current" : "match") : null });
      start = end;
    }
    offset += span.text.length;
  }
  return out;
}

function codeCell(line, className, matches = [], current = null) {
  const td = el("td", `code ${className}`);
  if (!line) return td;
  for (const p of pieces(line, matches, current)) {
    const span = el(p.mark ? "mark" : "span", p.mark === "current" ? "current" : undefined, p.text);
    if (p.style) span.setAttribute("style", p.style);
    td.append(span);
  }
  if (line.noNewlineAtEnd) td.append(el("span", "del", "  ⏎ no newline at end of file"));
  return td;
}

// ---- Rows ------------------------------------------------------------------------

function fileHeaderRow(path, info, viewedErrors) {
  const tr = el("tr", "filehead");
  tr.dataset.path = path;
  const td = el("td");
  td.colSpan = 4;
  const inner = el("div", "inner");

  const caret = el("button", "caret", info.collapsed ? "▸" : "▾");
  caret.title = info.collapsed ? "Open" : "Close";
  caret.addEventListener("click", () => window.diffApi.toggle(path));

  const check = el("input");
  check.type = "checkbox";
  check.checked = info.viewed;
  check.title = "Viewed";
  check.addEventListener("change", () => window.diffApi.setViewed(path, check.checked));

  const name = info.previousPath ? `${info.previousPath} → ${path}` : path;
  inner.append(caret, check, el("span", "path", name), el("span", "add", `+${info.additions}`), el("span", "del", `−${info.deletions}`));
  if (viewedErrors[path]) inner.append(el("span", "err", viewedErrors[path]));
  td.append(inner);
  tr.append(td);
  return tr;
}

function simpleRow(className, text) {
  const tr = el("tr", className);
  const td = el("td", undefined, text);
  td.colSpan = 4;
  tr.append(td);
  return tr;
}

function numCell(value, heat) {
  const td = el("td", "num", value ?? "");
  if (heat) {
    td.dataset.level = heat.level;
    td.style.setProperty("--score", heat.score);
    if (heat.uncertain) td.dataset.uncertain = "";
  }
  return td;
}

function lineRow(line, matches, current) {
  const tr = el("tr", line.kind);
  tr.append(numCell(line.oldNumber, line.heat), numCell(line.newNumber, null), el("td", "sign", line.kind === "added" ? "+" : line.kind === "removed" ? "-" : " "), codeCell(line, "", matches, current));
  return tr;
}

function pairRow(left, right, leftMatches, rightMatches, current) {
  const tr = el("tr");
  const side = (line) => (line ? line.kind : "blank");
  tr.append(
    numCell(left?.oldNumber, left?.heat),
    codeCell(left, side(left), leftMatches, current),
    numCell(right?.newNumber, right?.heat),
    codeCell(right, side(right), rightMatches, current),
  );
  return tr;
}

function render(state) {
  if (!state) return;
  document.documentElement.style.setProperty("--code-font", state.font.family);
  document.documentElement.style.setProperty("--code-size", `${state.font.size}px`);
  document.documentElement.style.setProperty("--code-ligatures", state.font.ligatures ? "normal" : "none");

  $("title").textContent = `${state.repo} #${state.number} — ${state.title}`;
  $("count").textContent = state.counts.review ? `${state.counts.viewed} of ${state.counts.review} viewed${state.counts.setAside ? ` · ${state.counts.setAside} set aside` : ""}` : "";
  $("layout").value = state.layout;

  const [text, bad] = state.phase === "failed" ? [`Could not load: ${state.error}`, true] : state.isTruncated ? ["GitHub lists at most 3000 files; the rest cannot be shown, so Merge stays off.", false] : (BANNERS[state.phase] ?? [null]);
  $("banner").hidden = !text;
  $("banner").textContent = text ?? "";
  $("banner").className = bad ? "banner bad" : "banner";

  $("merge").hidden = state.kind !== "own";
  $("merge").disabled = !state.canMerge;
  $("approve").hidden = state.kind !== "review";
  $("approve").disabled = !state.canApprove;

  if (document.activeElement !== $("find")) $("find").value = state.find.query;
  $("findCount").textContent = state.find.query ? (state.find.total ? `${state.find.current + 1} / ${state.find.total}` : "none") : "";

  renderScore(state);
  renderDescription(state.description);
  renderSidebar(state);
  renderRows(state);
}

function renderScore(state) {
  const s = state.score;
  const button = $("score");
  button.hidden = !s.offered || s.requested;
  button.disabled = state.phase !== "loaded";
  button.title = s.hasKey ? "Score how closely each block needs reviewing (sends the changed lines to OpenRouter)" : "Needs an OpenRouter key: add one in Settings";
  $("scoreInfo").textContent = s.stopped ?? (s.progress ? `Scoring ${s.progress.scored} of ${s.progress.total}…` : "");
  $("scoreInfo").style.color = s.stopped ? "var(--bad)" : "";
}

function renderMarks(state, tbody) {
  const marks = $("marks");
  marks.replaceChildren();
  for (const m of state.heatMarks) {
    const tick = el("i", `l${m.level}`);
    tick.style.top = `calc(${m.fraction * 100}% )`;
    tick.title = m.level === 3 ? "Sensitive" : "Business logic";
    tick.addEventListener("click", () => tbody.children[m.row]?.scrollIntoView({ block: "center" }));
    marks.append(tick);
  }
}

function renderSidebar(state) {
  const query = $("filter").value.trim().toLowerCase();
  const nav = $("files");
  nav.replaceChildren();
  for (const group of state.sidebar) {
    const files = group.files.filter((f) => !query || f.path.toLowerCase().includes(query));
    if (files.length === 0) continue;
    nav.append(el("div", "heading", group.heading));
    for (const f of files) {
      const row = el("div", f.viewed ? "file viewed" : "file");
      if (f.heat) {
        const dot = el("span", f.heat.state === "scored" ? `dot l${f.heat.level}` : `dot ${f.heat.state}`);
        dot.title = f.heat.state === "failed" ? f.heat.message : f.heat.state === "waiting" ? "Waiting to be scored" : ["Glue", "Routine", "Business logic", "Sensitive"][f.heat.level];
        row.append(dot);
      }
      row.append(el("span", "name", f.path), el("span", "add", `+${f.additions}`), el("span", "del", `−${f.deletions}`));
      row.addEventListener("click", () => {
        window.diffApi.prioritise(f.path);
        scrollToFile(f.path);
      });
      nav.append(row);
    }
  }
}

function scrollToFile(path) {
  for (const tr of document.querySelectorAll("tr.filehead")) {
    if (tr.dataset.path === path) return tr.scrollIntoView();
  }
}

let lastCurrent = null;

function renderRows(state) {
  const infoByPath = new Map(state.sidebar.flatMap((g) => g.files).map((f) => [f.path, f]));
  const matchesByRow = new Map();
  for (const m of state.find.matches) {
    const key = `${m.row}:${m.column}`;
    if (!matchesByRow.has(key)) matchesByRow.set(key, []);
    matchesByRow.get(key).push(m);
  }
  const current = state.find.current === null ? null : state.find.matches[state.find.current];

  const table = el("table");
  const body = el("tbody");
  state.rows.forEach((row, index) => {
    const forRow = (column) => matchesByRow.get(`${index}:${column}`) ?? [];
    switch (row.type) {
      case "fileHeader": body.append(fileHeaderRow(row.path, infoByPath.get(row.path), state.viewedErrors)); break;
      case "section": body.append(simpleRow("section", `${row.title} · ${row.count}`)); break;
      case "hunkHeader": body.append(simpleRow("hunk", row.text)); break;
      case "omitted": body.append(simpleRow("omitted", OMITTED[row.reason])); break;
      case "line": body.append(lineRow(row.line, forRow(0), current)); break;
      case "pair": body.append(pairRow(row.left, row.right, forRow(0), forRow(1), current)); break;
    }
  });
  table.append(body);

  const diff = $("diff");
  const scrollTop = diff.scrollTop;
  diff.replaceChildren();
  if (state.rows.length === 0 && state.phase === "loaded") diff.append(el("div", "empty", "No file changes."));
  diff.append(table);
  renderMarks(state, body);
  diff.scrollTop = scrollTop; // colour arriving file by file must not move the reader

  if (current && current !== lastCurrent) document.querySelector("mark.current")?.scrollIntoView({ block: "center" });
  lastCurrent = current;
}

// ---- Wiring ----------------------------------------------------------------------

let latest = null;
const apply = (state) => {
  latest = state;
  render(state);
};

$("reload").addEventListener("click", () => window.diffApi.reload());
$("merge").addEventListener("click", () => window.diffApi.merge());
$("approve").addEventListener("click", () => window.diffApi.approve());
$("score").addEventListener("click", () => window.diffApi.score());
$("layout").addEventListener("change", () => window.diffApi.setLayout($("layout").value));
$("filter").addEventListener("input", () => latest && renderSidebar(latest));
$("find").addEventListener("input", () => window.diffApi.find($("find").value));
$("find").addEventListener("keydown", (e) => {
  if (e.key === "Enter") window.diffApi.findStep(e.shiftKey ? -1 : 1);
  if (e.key === "Escape") {
    $("find").value = "";
    window.diffApi.find("");
  }
});
$("findNext").addEventListener("click", () => window.diffApi.findStep(1));
$("findPrev").addEventListener("click", () => window.diffApi.findStep(-1));
document.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f") {
    e.preventDefault();
    $("find").focus();
    $("find").select();
  }
});

window.diffApi.onState(apply);
window.diffApi.state().then(apply);
