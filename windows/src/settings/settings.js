const form = document.getElementById("form");
let snapshot = null;

function el(tag, props = {}, ...children) {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children);
  return node;
}

async function save(key, value) {
  const error = await window.settingsApi.set(key, value);
  if (error) alert(error);
}

const row = (label, control, hint) => {
  const wrap = el("label", { className: "row" }, el("span", {}, label), control);
  if (hint) wrap.title = hint;
  return wrap;
};

function checkbox(key, label, hint, disabled = false) {
  const input = el("input", { type: "checkbox", checked: snapshot.values[key], disabled });
  input.addEventListener("change", () => save(key, input.checked));
  return row(label, input, hint);
}

function select(key, label, options) {
  const current = JSON.stringify(snapshot.values[key]);
  const input = el("select", {}, ...options.map(([value, text]) => el("option", { value: JSON.stringify(value), textContent: text, selected: JSON.stringify(value) === current })));
  input.addEventListener("change", () => save(key, JSON.parse(input.value)));
  return row(label, input);
}

function textInput(key, label, { placeholder = "", width = "280px", hint, list } = {}) {
  const input = el("input", { value: snapshot.values[key] ?? "", placeholder, style: `width: ${width}` });
  if (list) input.setAttribute("list", list);
  input.addEventListener("change", () => save(key, input.value.trim() || null));
  return row(label, input, hint);
}

// A list of names with a checkbox each, ticked when *shown*: the setting stores
// what is hidden, so a new organization or team is visible until the user names it.
function shownList(key, items) {
  const hidden = new Set(snapshot.values[key]);
  const box = el("div");
  for (const item of items) {
    const input = el("input", { type: "checkbox", checked: !hidden.has(item.id) });
    input.addEventListener("change", () => {
      const next = new Set(snapshot.values[key]);
      if (input.checked) next.delete(item.id);
      else next.add(item.id);
      save(key, [...next]);
    });
    box.append(el("label", { className: "row" }, el("span", {}, item.label), el("span", { className: "count" }, item.note ?? ""), input));
  }
  return box;
}

const SPANS = {
  stale: [[null, "Off"], [14, "2 weeks"], [30, "1 month"], [90, "3 months"], [180, "6 months"]],
  merged: [[null, "Off"], [1, "1 day"], [3, "3 days"], [7, "1 week"]],
  review: [[7, "1 week"], [14, "2 weeks"], [30, "1 month"]],
};

const MONO_FONTS = ["Consolas", "Cascadia Code", "Cascadia Mono", "JetBrains Mono", "Fira Code", "Source Code Pro", "Courier New"];

function patternEditor(section) {
  const base = snapshot.values.diffSectionPatterns ?? snapshot.context.defaultPatterns;
  const area = el("textarea", { value: (base[section] ?? []).join("\n"), spellcheck: false });
  area.addEventListener("change", () => {
    const current = snapshot.values.diffSectionPatterns ?? snapshot.context.defaultPatterns;
    save("diffSectionPatterns", { ...current, [section]: area.value.split("\n") });
  });
  const invalid = snapshot.context.invalidPatterns[section] ?? [];
  const title = `${section[0].toUpperCase()}${section.slice(1)}: .gitignore-style patterns, one per line. The last match wins; ! re-includes.`;
  return el("div", {}, el("div", { className: "hint" }, title), area, invalid.length ? el("div", { className: "bad" }, `Not valid, ignored: ${invalid.join("  ")}`) : "");
}

function openRouterKey(c) {
  const input = el("input", { type: "password", placeholder: c.secrets.openRouterKey ? "saved: type to replace" : "OpenRouter API key", style: "width: 280px", disabled: !c.secrets.available });
  input.addEventListener("change", async () => {
    const error = await window.settingsApi.setSecret("openrouter-key", input.value.trim());
    if (error) alert(error);
    input.value = "";
  });
  const remove = el("button", { textContent: "Remove", disabled: !c.secrets.openRouterKey });
  remove.addEventListener("click", () => window.settingsApi.setSecret("openrouter-key", ""));
  return row("OpenRouter key", el("span", {}, input, " ", remove), "Stored encrypted with your Windows account.");
}

function fontSize() {
  const input = el("input", { type: "number", min: 8, max: 32, value: snapshot.values.diffFontSize, style: "width: 64px" });
  input.addEventListener("change", () => save("diffFontSize", Number(input.value)));
  return row("Font size", input);
}

function resetPatterns() {
  const button = el("button", { textContent: "Reset patterns to defaults" });
  button.addEventListener("click", () => save("diffSectionPatterns", null));
  return el("div", { className: "actions" }, button);
}

// ---- Board: Jira sign-in and GitHub projects --------------------------------------

const LANE_CHOICES = [["hidden", "Hidden"], ["toDo", "To do"], ["inProgress", "In progress"], ["reviewing", "Reviewing"], ["testing", "Testing"], ["done", "Done"]];

function jiraSection(jira) {
  if (jira.signedIn) {
    const who = jira.name ? `Signed in as ${jira.name} (${jira.email}) on ${jira.baseURL}` : `Signed in as ${jira.email} on ${jira.baseURL}`;
    const out = el("button", { textContent: "Sign out" });
    out.addEventListener("click", async () => {
      const error = await window.settingsApi.board.signOut();
      if (error) alert(error);
    });
    return el("div", { className: "row" }, el("span", {}, who), out);
  }
  const site = el("input", { placeholder: "https://acme.atlassian.net", style: "width: 280px" });
  const email = el("input", { placeholder: "you@company.com", style: "width: 280px" });
  const token = el("input", { type: "password", placeholder: "API token from id.atlassian.com → Security", style: "width: 280px" });
  const message = el("div", { className: "bad" });
  const go = el("button", { textContent: "Test and sign in", className: "primary" });
  go.addEventListener("click", async () => {
    message.textContent = "Testing…";
    message.style.color = "var(--muted)";
    go.disabled = true;
    const error = await window.settingsApi.board.signIn({ baseURL: site.value, email: email.value, apiToken: token.value });
    go.disabled = false;
    message.style.color = "";
    message.textContent = error ?? "";
    if (!error) token.value = "";
  });
  return el("div", {}, row("Jira site", site), row("Email", email), row("API token", token), el("p", { className: "hint" }, "Nothing is stored until it has been tested. The token goes in your Windows-encrypted store and is sent only to your own Jira site."), el("div", { className: "actions" }, go), message);
}

function projectsSection(board) {
  const find = el("button", { textContent: "Find projects" });
  find.addEventListener("click", async () => {
    find.disabled = true;
    const error = await window.settingsApi.board.discover();
    find.disabled = false;
    if (error) alert(error);
  });
  const nodes = [el("div", { className: "actions" }, find)];
  if (board.discoveryError) nodes.push(el("div", { className: "bad" }, board.discoveryError));
  if (board.projects.length === 0) nodes.push(el("p", { className: "hint" }, "No projects yet: press Find projects. Reading them needs the project scope on your GitHub token."));
  for (const p of board.projects) {
    const on = el("input", { type: "checkbox", checked: p.shown, disabled: !p.hasStatus });
    on.addEventListener("change", async () => {
      const error = await window.settingsApi.board.projectShown(p.id, on.checked);
      if (error) alert(error);
    });
    nodes.push(el("label", { className: "row" }, el("span", {}, `${p.owner}/${p.title}`), el("span", { className: "count" }, p.hasStatus ? "" : "no Status field"), on));
    if (p.shown) nodes.push(columnsFor(p));
  }
  return el("div", {}, ...nodes);
}

// Where each Status option lands on the board; kept by option id, so renaming a column on GitHub keeps the choice.
function columnsFor(project) {
  const picker = (optionID, name, choice) => {
    const select = el("select", {}, ...LANE_CHOICES.map(([value, text]) => el("option", { value, textContent: text, selected: value === choice })));
    select.addEventListener("change", async () => {
      const error = await window.settingsApi.board.projectChoice(project.id, optionID, select.value);
      if (error) alert(error);
    });
    return el("label", { className: "row", style: "padding-left: 24px" }, el("span", {}, name), select);
  };
  return el("details", {}, el("summary", {}, "Columns"), ...project.options.map((o) => picker(o.id, o.name, o.choice)), picker("", "No Status", project.noStatusChoice));
}

function render() {
  const c = snapshot.context;
  form.replaceChildren(
    el("h2", {}, "General"),
    checkbox("autoUpdateBranches", "Keep branches up to date", "Merges the base branch into your behind pull requests, like GitHub's Update branch button. Off until you turn it on: it pushes commits to your branches."),
    checkbox("launchAtLogin", "Launch at login", c.packaged ? "" : "Only in the installed app", !c.packaged),
    select("theme", "Theme", [["system", "Match Windows"], ["light", "Light"], ["dark", "Dark"]]),
    checkbox("hideTitleEmoji", "Hide the emoji in titles", ":shortcodes: in titles are shown as emoji unless this is on."),

    el("h2", {}, "Lists"),
    select("staleDays", "Mark pull requests open longer than", SPANS.stale),
    select("mergedWindowDays", "Recently merged reaches back", SPANS.merged),
    select("reviewWindowDays", "Review requests opened within", SPANS.review),

    el("h2", {}, "Filters"),
    checkbox("showPrivateRepositories", "Show pull requests from private repositories"),
    el("p", { className: "hint" }, "Organizations (untick to hide):"),
    c.organizations.length ? shownList("hiddenOrganizations", c.organizations.map((o) => ({ id: o, label: o }))) : el("p", { className: "hint" }, "None seen yet."),
    el("p", { className: "hint" }, "Teams whose review requests are listed:"),
    c.teams.length
      ? shownList("disabledTeams", c.teams.map((t) => ({ id: t.slug, label: t.slug, note: t.pending === null ? "" : `${t.pending} waiting` })))
      : el("p", { className: "hint" }, "No teams loaded (the token needs the read:org scope)."),

    el("h2", {}, "Diff viewer"),
    select("diffLayout", "Layout", [["unified", "Unified"], ["split", "Split"]]),
    textInput("diffFontFamily", "Font", { placeholder: "Consolas", width: "200px", list: "fonts" }),
    el("datalist", { id: "fonts" }, ...MONO_FONTS.map((f) => el("option", { value: f }))),
    fontSize(),
    checkbox("diffLigatures", "Ligatures"),
    checkbox("honoursGitAttributes", "Honour linguist-generated in .gitattributes", "Files the repository marks as generated are set aside."),
    el("p", { className: "hint" }, "Files set aside below the review, by pattern:"),
    ...["tests", "generated", "other"].map(patternEditor),
    resetPatterns(),

    el("h2", {}, "Board"),
    jiraSection(c.board.jira),
    select("jiraWindowDays", "Done reaches back", [[null, "Off"], [7, "1 week"], [14, "2 weeks"], [30, "1 month"]]),
    select("boardLayout", "Layout", [["list", "List"], ["board", "Board"]]),
    el("p", { className: "hint" }, "GitHub projects (only items assigned to you appear; all off until you turn them on):"),
    projectsSection(c.board),

    checkbox("approvalQuips", "Add a remark when approving", "Posts a short, tongue-in-cheek line chosen from the pull request's size and state. You see it in the confirmation first."),

    el("h2", {}, "Score"),
    checkbox("heatmapEnabled", "Offer Score in review windows", "Sends changed lines to OpenRouter (or your proxy) only when you press Score."),
    textInput("heatmapBaseURL", "Proxy URL", { placeholder: "https://openrouter.ai/api (default)", hint: "https:// only" }),
    openRouterKey(c),
  );
}

window.settingsApi.onChanged((s) => {
  snapshot = s;
  // Keep what is being typed: re-rendering mid-edit would drop it.
  if (!document.activeElement || document.activeElement === document.body) render();
});
window.settingsApi.all().then((s) => {
  snapshot = s;
  render();
});
