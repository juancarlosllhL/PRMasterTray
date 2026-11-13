import { BrowserWindow, dialog, ipcMain, nativeTheme, shell } from "electron";
import { Worker } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { approvePullRequest, squashMerge } from "./core/github.js";
import { loadDiff, mergeTarget, observeLive, setViewed } from "./core/diff.js";
import { diffPayload } from "./core/diffPayload.js";
import { DiffView } from "./core/diffView.js";
import { DEFAULT_PATTERNS } from "./core/fileScope.js";
import { highlightFile, languageForPath } from "./core/highlight.js";
import { createJevClient, parseEndpoint } from "./core/score.js";
import { prepareScoring, scoreFiles } from "./core/scoring.js";
import { quipFor } from "./core/approvalQuip.js";
import { readToken } from "./core/token.js";
import { createWorkerClient } from "./core/workerClient.js";

const PUSH_EVERY_MS = 120; // colour arrives file by file; repainting for each would be wasteful

// One window per pull request. A window is pinned to the commit it loaded: if
// somebody pushes while it is open it says so, and Merge and Approve stay off
// until it has been reloaded, so GitHub is always asked to act on exactly what
// was read.
//
// `subjectOf(kind, id)` returns the live row for a pull request — an open PR of
// the user's ("own") or a review request ("review") — or undefined when the list
// does not hold it. `onChanged` runs after a write so the main list refreshes.
export function createDiffWindows({ preload, page, settings, secrets, subjectOf, onChanged }) {
  const byKey = new Map(); // "kind:id" -> entry
  const byContents = new Map(); // webContents id -> entry

  const entryFor = (event) => byContents.get(event.sender.id);

  // ---- Syntax colour: one worker for every window ---------------------------

  let client = null;
  const highlighter = (segments, language, theme) => {
    if (!client) {
      const worker = new Worker(fileURLToPath(new URL("./highlightWorker.js", import.meta.url)));
      client = createWorkerClient(worker);
      worker.on("exit", () => (client = null)); // started again on the next request
    }
    return client.request({ segments, language, theme }).then((answer) => answer.json);
  };

  const syntaxTheme = () => (nativeTheme.shouldUseDarkColors ? "github-dark-default" : "github-light-default");

  async function highlightAll(entry) {
    const generation = ++entry.highlightGeneration;
    const theme = syntaxTheme();
    const files = entry.view.groups.flatMap((g) => g.files).filter((f) => f.content.kind === "hunks" && languageForPath(f.path));
    for (const file of files) {
      if (entry.highlightGeneration !== generation || entry.win.isDestroyed()) return;
      const coloured = await highlightFile(file, theme, highlighter);
      if (entry.highlightGeneration !== generation || entry.win.isDestroyed()) return;
      const index = entry.diff.files.findIndex((f) => f.path === file.path);
      if (index < 0) continue;
      // The reviewer may have ticked Viewed while this was in the worker.
      entry.diff.files[index] = { ...coloured, viewed: entry.diff.files[index].viewed };
      entry.view.rebuild();
      schedulePush(entry);
    }
  }

  // ---- Score: nothing is sent until the reviewer asks ----------------------

  const hasKey = () => Boolean(secrets?.has("openrouter-key"));
  const showsHeat = (entry) => settings.get("heatmapEnabled") && entry.scoring.requested;

  function scoreStateOf(entry) {
    const states = [...entry.view.fileHeat.values()];
    const waiting = states.filter((h) => h.state === "waiting").length;
    return {
      offered: settings.get("heatmapEnabled"),
      hasKey: hasKey(),
      requested: entry.scoring.requested,
      stopped: entry.scoring.stopped,
      progress: waiting === 0 || !entry.scoring.requested ? null : { scored: states.length - waiting, total: states.length },
    };
  }

  async function startScoring(entry) {
    const run = ++entry.scoring.generation;
    entry.scoring.stopped = null;
    const token = secrets?.get("openrouter-key");
    if (!token) {
      entry.scoring.stopped = "Add an OpenRouter key in Settings.";
      return push(entry);
    }
    let endpoint;
    try {
      endpoint = parseEndpoint(settings.get("heatmapBaseURL") ?? "");
    } catch (e) {
      entry.scoring.stopped = e.message;
      return push(entry);
    }
    const files = entry.diff.files; // the loaded diff itself: heat is drawn on copies
    const { heat, scores } = prepareScoring(files, entry.scoring.cache);
    for (const [path, state] of heat) entry.view.setFileHeat(path, state);
    for (const [path, list] of scores) entry.view.setScores(path, list);
    entry.view.setHeatShown(showsHeat(entry));
    push(entry);

    const current = () => run === entry.scoring.generation && !entry.win.isDestroyed();
    await scoreFiles({
      files,
      client: createJevClient({ token, endpoint }),
      cache: entry.scoring.cache,
      priorityPath: entry.priorityPath,
      isCancelled: () => !current(),
      onFile: (path, result) => {
        if (!current()) return;
        entry.view.setFileHeat(path, { state: result.state, level: result.level, message: result.message });
        if (result.scores) entry.view.setScores(path, result.scores);
        schedulePush(entry);
      },
      onStop: (message) => {
        entry.scoring.stopped = message;
        push(entry);
      },
    });
  }

  // ---- State sent to the window ---------------------------------------------

  // null = gone from the list (merged or closed elsewhere); undefined = list not loaded yet.
  function liveHead(entry) {
    const subject = subjectOf(entry.kind, entry.id);
    if (subject === undefined) return undefined;
    return subject?.headRefOid ?? null;
  }

  function phaseOf(entry) {
    if (entry.phase !== "loaded" || !entry.diff) return entry.phase;
    return observeLive(entry.diff, liveHead(entry));
  }

  function targetOf(entry) {
    const subject = subjectOf(entry.kind, entry.id);
    const isReady = entry.kind === "own" && subject?.readiness === "ready";
    return mergeTarget({ phase: phaseOf(entry), isReady, diff: entry.diff });
  }

  // Only someone else's pull request can be approved; your own is merged from its row.
  const canApprove = (entry) => entry.kind === "review" && phaseOf(entry) === "loaded" && !entry.diff.isTruncated;

  function viewOf(entry) {
    return diffPayload({
      meta: { title: entry.title, repo: entry.repo, number: entry.number, url: entry.url, kind: entry.kind },
      phase: phaseOf(entry),
      error: entry.error,
      viewedErrors: entry.viewedErrors,
      view: entry.view,
      isTruncated: entry.diff?.isTruncated ?? false,
      canMerge: Boolean(entry.diff && targetOf(entry)),
      canApprove: Boolean(entry.diff && canApprove(entry)),
      settings: settings.all(),
      description: entry.diff?.descriptionHTML ?? null,
      score: scoreStateOf(entry),
    });
  }

  const push = (entry) => {
    entry.pushTimer = null;
    if (!entry.win.isDestroyed()) entry.win.webContents.send("diff:state", viewOf(entry));
  };

  function schedulePush(entry) {
    entry.pushTimer ??= setTimeout(() => push(entry), PUSH_EVERY_MS);
  }

  const patternsFromSettings = () => settings.get("diffSectionPatterns") ?? DEFAULT_PATTERNS;
  const attributesFor = (diff) => (settings.get("honoursGitAttributes") ? (diff.gitAttributes ?? null) : null);

  // ---- Loading ---------------------------------------------------------------

  async function load(entry) {
    entry.phase = "loading";
    entry.error = null;
    entry.viewedErrors = {};
    entry.highlightGeneration++;
    entry.scoring.generation++;
    push(entry);
    try {
      entry.diff = await loadDiff({ token: await readToken(), repo: entry.repo, number: entry.number });
      entry.view = new DiffView({ layout: settings.get("diffLayout"), patterns: patternsFromSettings() });
      entry.view.load({ ...entry.diff, gitAttributes: attributesFor(entry.diff) });
      entry.phase = "loaded";
    } catch (e) {
      entry.phase = "failed";
      entry.error = e.message;
    }
    push(entry);
    if (entry.phase === "loaded") {
      highlightAll(entry);
      if (entry.scoring.requested) startScoring(entry); // reloads in this window keep scoring
    }
  }

  function open(kind, id) {
    const key = `${kind}:${id}`;
    const existing = byKey.get(key);
    if (existing) {
      existing.win.show();
      existing.win.focus();
      return existing;
    }
    const subject = subjectOf(kind, id);
    if (!subject) return null;

    const win = new BrowserWindow({
      width: 1200,
      height: 800,
      title: `${subject.repo} #${subject.number} — ${subject.title}`,
      autoHideMenuBar: true,
      webPreferences: { preload, contextIsolation: true },
    });
    const entry = {
      win, key, kind, id,
      contentsId: win.webContents.id, // read at close time, when the contents are already gone
      repo: subject.repo, number: subject.number, title: subject.title, url: subject.url,
      diff: null, view: new DiffView({ layout: settings.get("diffLayout"), patterns: patternsFromSettings() }),
      phase: "loading", error: null, viewedErrors: {}, highlightGeneration: 0, pushTimer: null,
      // The cache outlives reloads, so a push only pays for the blocks it changed.
      scoring: { requested: false, stopped: null, generation: 0, cache: new Map() }, priorityPath: null,
    };
    byKey.set(key, entry);
    byContents.set(entry.contentsId, entry);
    win.on("closed", () => {
      entry.highlightGeneration++;
      entry.scoring.generation++;
      clearTimeout(entry.pushTimer);
      byKey.delete(key);
      byContents.delete(entry.contentsId);
    });
    win.loadFile(page);
    load(entry);
    return entry;
  }

  // ---- Writes ----------------------------------------------------------------

  async function confirm(entry, { message, button, remark }) {
    const { response } = await dialog.showMessageBox(entry.win, {
      type: "question",
      message,
      detail: `${entry.repo}\n${entry.title}${remark ? `\n\nRemark to post: ${remark}` : ""}`,
      buttons: [button, "Cancel"],
      defaultId: 1,
      cancelId: 1,
    });
    return response === 0;
  }

  // Merge or approve, each re-checked at the moment of the click: what the
  // renderer drew may be older than the live row.
  async function write(entry, { allowed, message, button, remark, run, closeOnSuccess }) {
    if (!allowed()) return;
    if (!(await confirm(entry, { message, button, remark }))) return;
    try {
      await run(await readToken());
    } catch (e) {
      dialog.showErrorBox("PR Master", e.message);
      return;
    } finally {
      await onChanged();
    }
    if (closeOnSuccess && !entry.win.isDestroyed()) entry.win.close();
  }

  // ---- Messages from the windows --------------------------------------------

  const onEntry = (channel, handler) =>
    ipcMain.on(channel, (event, ...args) => {
      const entry = entryFor(event);
      if (entry) handler(entry, ...args);
    });

  ipcMain.handle("diff:state", (event) => {
    const entry = entryFor(event);
    return entry ? viewOf(entry) : null;
  });

  onEntry("diff:reload", (entry) => load(entry));

  onEntry("diff:toggle", (entry, path) => {
    if (!entry.view.files.some((f) => f.path === path)) return;
    entry.view.toggleCollapsed(path);
    push(entry);
  });

  onEntry("diff:layout", (_entry, layout) => {
    if (layout === "unified" || layout === "split") settings.set("diffLayout", layout);
  });

  onEntry("diff:score", (entry) => {
    if (!settings.get("heatmapEnabled") || entry.scoring.requested || !entry.diff) return;
    entry.scoring.requested = true;
    startScoring(entry);
  });

  onEntry("diff:prioritise", (entry, path) => {
    entry.priorityPath = path;
  });

  onEntry("diff:find", (entry, query) => {
    entry.view.setFindQuery(String(query));
    push(entry);
  });

  onEntry("diff:findStep", (entry, direction) => {
    if (direction > 0) entry.view.findNext();
    else entry.view.findPrevious();
    push(entry);
  });

  onEntry("diff:openLink", (_entry, url) => {
    if (typeof url === "string" && url.startsWith("https://")) shell.openExternal(url);
  });

  onEntry("diff:viewed", async (entry, path, viewed) => {
    const file = entry.diff?.files.find((f) => f.path === path);
    if (!file) return;
    const previous = file.viewed === "VIEWED";
    entry.view.setViewedLocally(path, viewed);
    delete entry.viewedErrors[path];
    push(entry);
    try {
      await setViewed({ token: await readToken(), pullRequestID: entry.diff.pullRequestID, path, viewed });
    } catch (e) {
      entry.view.setViewedLocally(path, previous);
      entry.viewedErrors[path] = e.message;
    }
    push(entry);
  });

  onEntry("diff:merge", (entry) => {
    write(entry, {
      allowed: () => targetOf(entry) !== null,
      message: `Squash-merge #${entry.number}?`,
      button: "Merge",
      // Pinned to the commit that was read, not to whatever the head is now.
      run: (token) => {
        const target = targetOf(entry);
        if (!target) throw new Error("The pull request changed; reload before merging.");
        return squashMerge({ token, id: target.id, expectedHeadOid: target.oid });
      },
      closeOnSuccess: true,
    });
  });

  onEntry("diff:approve", (entry) => {
    // Chosen once, so the remark shown in the confirmation is the one posted.
    const subject = subjectOf(entry.kind, entry.id);
    const remark = subject && settings.get("approvalQuips") ? quipFor(subject, new Date()) : undefined;
    write(entry, {
      remark,
      allowed: () => canApprove(entry),
      message: "Approve this pull request?",
      button: "Approve",
      run: (token) => {
        if (!canApprove(entry)) throw new Error("The pull request changed; reload before approving.");
        return approvePullRequest({ token, id: entry.diff.pullRequestID, commitOID: entry.diff.headOid, body: remark });
      },
      closeOnSuccess: true,
    });
  });

  // ---- Settings and theme changes reach windows that are already open -------

  const eachLoaded = (fn) => byKey.forEach((entry) => entry.diff && fn(entry));

  settings.onChange((key) => {
    if (key === "diffLayout") eachLoaded((e) => (e.view.setLayout(settings.get("diffLayout")), push(e)));
    else if (key === "diffSectionPatterns") eachLoaded((e) => (e.view.reclassify({ patterns: patternsFromSettings() }), push(e)));
    else if (key === "honoursGitAttributes") eachLoaded((e) => (e.view.reclassify({ gitAttributes: attributesFor(e.diff) }), push(e)));
    else if (key.startsWith("diffFont") || key === "diffLigatures") byKey.forEach(push);
    else if (key === "heatmapEnabled") eachLoaded((e) => (e.view.setHeatShown(showsHeat(e)), push(e)));
  });

  // The colours are chosen for the theme, so a theme change colours again.
  nativeTheme.on("updated", () => eachLoaded(highlightAll));

  return {
    open,
    // Called after every list refresh: a push, a merge or a close elsewhere changes what these windows may do.
    observe: () => byKey.forEach(push),
    // For the self test: what the window on this pull request is showing.
    entry: (kind, id) => byKey.get(`${kind}:${id}`),
  };
}
