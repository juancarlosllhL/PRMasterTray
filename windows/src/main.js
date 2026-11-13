import { app, BrowserWindow, clipboard, screen, dialog, Menu, nativeImage, nativeTheme, Notification, powerMonitor, Tray, ipcMain, shell } from "electron";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createBoardRuntime } from "./boardRuntime.js";
import { ACTIONS } from "./core/actions.js";
import { decideBranchUpdates } from "./core/branchUpdate.js";
import { newDeploymentsState } from "./core/deployments.js";
import { PullRequestFilter } from "./core/filter.js";
import { fetchMyPullRequests, fetchShipments, updateBranch } from "./core/github.js";
import { renderEmoji, stripEmoji } from "./core/emoji.js";
import { decide } from "./core/notification.js";
import { fetchReviewRequests, fetchTeams, reviewRows } from "./core/reviews.js";
import { rows, shipmentRows } from "./core/rows.js";
import { createSettings } from "./core/settings.js";
import { readToken } from "./core/token.js";
import { createDiffWindows } from "./diffWindow.js";
import { AppUpdate, checkLatestRelease } from "./core/appUpdate.js";
import { parseChangelog, whatsNewEntries } from "./core/changelog.js";
import { createSecrets } from "./secrets.js";
import { withEnvFallback } from "./core/secretsEnv.js";
import { createUpdateInstaller } from "./updater.js";
import { createWhatsNewWindow } from "./whatsNewWindow.js";
import { runSelfTest } from "./selfTest.js";
import { createSettingsWindow } from "./settingsWindow.js";
import { BOARD_LANES } from "./core/jira.js";

const POLL_MS = 60_000;

// Where releases are published: the repository this app is built from.
const releaseRepo = () => JSON.parse(fs.readFileSync(fileURLToPath(new URL("../package.json", import.meta.url)), "utf8")).repository.replace(/^github:/, "");
const here = (file) => fileURLToPath(new URL(file, import.meta.url));
const userFile = (name) => path.join(app.getPath("userData"), name);

let tray;
let win;
let diffs;
let settingsWindow;
let settings;
let secrets;
let board;
let update;
let whatsNew;
let changelog = [];
let quitting = false;
let notified = new Set();
let attemptedUpdates = new Set();
const deployments = newDeploymentsState();
let teams = null; // fetched once it succeeds; the list of teams rarely changes
let state = { prs: [], shipments: [], reviews: [], reviewError: null, teamCounts: {}, error: null, loaded: false };

// A filled disc, green when something is ready. Drawn rather than shipped so
// the tray needs no binary asset.
function icon(ready) {
  const size = 16;
  const buf = Buffer.alloc(size * size * 4);
  const [r, g, b] = ready ? [46, 160, 67] : [110, 118, 129];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const inside = (x - 7.5) ** 2 + (y - 7.5) ** 2 <= 49;
      buf.set(inside ? [b, g, r, 255] : [0, 0, 0, 0], (y * size + x) * 4); // BGRA
    }
  }
  return nativeImage.createFromBitmap(buf, { width: size, height: size });
}

// ---- Persistence ------------------------------------------------------------

function fileStore(name) {
  return {
    read: () => {
      try {
        return fs.readFileSync(userFile(name), "utf8");
      } catch {
        return null;
      }
    },
    write: (text) => fs.writeFileSync(userFile(name), text),
  };
}

// Where each repository deploys is discovered with a rate-limited code search,
// so it survives restarts: once per repository, ever. Bump the version when
// discovery learns to find more: an answer cached under the old rules ("deploys
// nothing") would otherwise be believed forever.
const LOCATIONS_VERSION = 2;

function loadLocations() {
  try {
    const saved = JSON.parse(fileStore("app-locations.json").read());
    if (saved.version === LOCATIONS_VERSION) deployments.locations = saved.locations;
  } catch {
    // Nothing discovered yet.
  }
}

function saveLocations() {
  fileStore("app-locations.json").write(JSON.stringify({ version: LOCATIONS_VERSION, locations: deployments.locations }));
}

// ---- Data -------------------------------------------------------------------

// The Board repaints as its sources change; a burst of changes is one repaint.
let boardTimer = null;
function pushBoard() {
  boardTimer ??= setTimeout(() => {
    boardTimer = null;
    if (win && !win.isDestroyed()) win.webContents.send("board", board.view());
    settingsWindow?.refresh();
  }, 80);
}

const currentFilter = () =>
  new PullRequestFilter({
    hiddenOrganizations: settings.get("hiddenOrganizations"),
    showPrivateRepositories: settings.get("showPrivateRepositories"),
  });

// Titles as a human should see them: :shortcodes: as emoji, or with the decoration taken out if asked.
const retitled = (items) => {
  const show = settings.get("hideTitleEmoji") ? stripEmoji : renderEmoji;
  return items.map((item) => ({ ...item, title: show(item.title) }));
};

// What the update row needs: an offer, whether it can be taken, and why a check or install failed.
const updateView = () => ({
  version: update?.availableRelease?.version ?? null,
  canInstall: update?.canInstall ?? false,
  installing: update?.isInstalling ?? false,
  failure: update?.lastInstallFailure ?? null,
});

const viewState = () => ({
  rows: retitled(rows(state.prs, new Date(), settings.get("staleDays"))),
  shipments: retitled(shipmentRows(state.shipments)),
  reviews: retitled(reviewRows(state.reviews)),
  reviewError: state.reviewError,
  update: updateView(),
  error: state.error,
  loaded: state.loaded,
});

async function updateBehindBranches(prs, token) {
  const { update, attempted } = decideBranchUpdates(prs, attemptedUpdates);
  attemptedUpdates = attempted;
  // A refused update stays recorded by its head oid, so a failure is not retried.
  await Promise.allSettled(update.map((p) => updateBranch({ token, id: p.id, expectedHeadOid: p.headRefOid })));
}

// Independent of the open list: a missing read:org scope must cost this section
// only, and say so, rather than blank the pull requests.
async function refreshReviews(token, filter) {
  try {
    teams ??= await fetchTeams({ token });
    const { requests, pendingCounts } = await fetchReviewRequests({
      token,
      teams,
      disabled: new Set(settings.get("disabledTeams")),
      windowDays: settings.get("reviewWindowDays"),
    });
    return { reviews: filter.apply(requests), reviewError: null, teamCounts: pendingCounts };
  } catch (e) {
    return { reviews: state.reviews, reviewError: e.message, teamCounts: state.teamCounts };
  }
}

async function refresh() {
  try {
    const token = await readToken();
    const filter = currentFilter();
    // Filtered before anything is decided: a hidden PR must not notify or have its branch updated.
    const prs = filter.apply(await fetchMyPullRequests({ token }));
    if (settings.get("autoUpdateBranches")) await updateBehindBranches(prs, token);
    const { notify, updated } = decide(prs, notified);
    notified = updated;
    for (const pr of notify) {
      const n = new Notification({ title: "Ready to merge", body: `${pr.repo} #${pr.number} — ${renderEmoji(pr.title)}` });
      n.on("click", showWindow);
      n.show();
    }
    // Recently merged is secondary: losing it must not cost the open list.
    const known = Object.keys(deployments.locations).length;
    const fetched = await fetchShipments({ token, deployments, windowDays: settings.get("mergedWindowDays") }).catch(() => state.shipments);
    if (Object.keys(deployments.locations).length !== known) saveLocations();
    const shipments = fetched.filter((s) => filter.includes(s.pr));
    const { reviews, reviewError, teamCounts } = await refreshReviews(token, filter);
    state = { prs, shipments, reviews, reviewError, teamCounts, error: null, loaded: true };
  } catch (e) {
    // Keep the last good list; a failed poll must not blank the window.
    state = { ...state, error: e.message, loaded: true };
  }
  const ready = state.prs.filter((p) => p.readiness === "ready").length;
  tray.setImage(icon(ready > 0));
  tray.setToolTip(`PR Master — ${ready} ready of ${state.prs.length}`);
  win.webContents.send("state", viewState());
  diffs?.observe();
}

// The row is looked up again here rather than trusted from the renderer: what
// the user clicked may have changed since it was drawn.
async function act(kind, id) {
  const action = ACTIONS[kind];
  const pr = state.prs.find((p) => p.id === id);
  const row = pr && rows([pr], new Date(), settings.get("staleDays"))[0];
  if (!action || !row || !action.allowed(row)) return;
  const { message, detail, button } = action.prompt(row);
  const { response } = await dialog.showMessageBox(win, { type: "question", message, detail, buttons: [button, "Cancel"], defaultId: 1, cancelId: 1 });
  if (response !== 0) return;
  try {
    await action.run({ token: await readToken(), fetchImpl: fetch }, pr);
  } catch (e) {
    dialog.showErrorBox("PR Master", e.message);
  }
  await refresh();
}

// ---- Context menus ----------------------------------------------------------
// Copy Link and Copy ID are on the right-click menu of every pull request and every
// board card. What arrives from the window is checked: it names things to copy and
// a column to move to, nothing else.

const isHttps = (v) => typeof v === "string" && v.startsWith("https://");

function popUpContextMenu(spec) {
  const items = [];
  if (spec?.kind === "card" && typeof spec.cardId === "string" && spec.canMove) {
    items.push({
      label: "Move to",
      submenu: BOARD_LANES.map((l) => ({ label: l.title, enabled: l.id !== spec.lane, click: () => board.move(spec.cardId, l.id) })),
    });
    items.push({ type: "separator" });
  }
  if (isHttps(spec?.url)) items.push({ label: "Copy Link", click: () => clipboard.writeText(spec.url) });
  if (typeof spec?.copyID === "string" && spec.copyID) items.push({ label: "Copy ID", click: () => clipboard.writeText(spec.copyID) });
  if (items.length) Menu.buildFromTemplate(items).popup({ window: win });
}

// ---- Windows ----------------------------------------------------------------

function createWindow() {
  win = new BrowserWindow({
    width: 480,
    height: 680,
    title: "PR Master",
    autoHideMenuBar: true,
    webPreferences: { preload: here("./preload.cjs"), contextIsolation: true },
  });
  win.loadFile(here("./renderer/index.html"));
  // Closing hides to the tray; only Quit really exits.
  win.on("close", (e) => {
    if (quitting) return;
    e.preventDefault();
    win.hide();
  });
}

function showWindow() {
  win.show();
  win.focus();
}

// What the settings window needs to know that only the poll can tell it.
const settingsContext = () => ({
  teams: (teams ?? []).map((t) => ({ slug: t.combinedSlug, name: t.name, pending: state.teamCounts[t.combinedSlug] ?? null })),
  organizations: [
    ...new Set([
      ...state.prs.map((p) => PullRequestFilter.organizationOf(p.repo)),
      ...state.shipments.map((s) => PullRequestFilter.organizationOf(s.pr.repo)),
      ...state.reviews.map((r) => PullRequestFilter.organizationOf(r.repo)),
      ...settings.get("hiddenOrganizations"),
    ]),
  ].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" })),
  packaged: app.isPackaged,
  board: board.settingsView(),
});

// Settings that change what the poll fetches or hides take effect at once.
const REFETCH = new Set(["hideTitleEmoji", "staleDays", "mergedWindowDays", "reviewWindowDays", "hiddenOrganizations", "showPrivateRepositories", "disabledTeams", "autoUpdateBranches"]);

function applySetting(key, value) {
  if (key === "jiraWindowDays" || key === "boardLayout" || key === "hiddenOrganizations" || key === "showPrivateRepositories") board?.settingChanged(key);
  if (key === "theme") nativeTheme.themeSource = value;
  // An unpackaged run would register Electron's own binary as the thing to start.
  if (key === "launchAtLogin" && app.isPackaged) app.setLoginItemSettings({ openAtLogin: value });
  if (REFETCH.has(key)) refresh();
  tray && rebuildTrayMenu();
}

// A manual check says how it went; the poll stays quiet unless there is something to offer.
async function checkForUpdates(manual) {
  await update.checkNow();
  if (!manual) return;
  const message = update.lastCheckFailure ? "Couldn't check for updates" : update.availableRelease ? `PR Master ${update.availableRelease.version} is available` : "PR Master is up to date";
  dialog.showMessageBox({ type: update.lastCheckFailure ? "warning" : "info", message, detail: update.lastCheckFailure ?? `You have ${app.getVersion()}.`, buttons: ["OK"] });
}

function rebuildTrayMenu() {
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: "Show", click: showWindow },
      { label: "Refresh", click: refresh },
      { label: "Keep branches up to date", type: "checkbox", checked: settings.get("autoUpdateBranches"), click: (item) => settings.set("autoUpdateBranches", item.checked) },
      ...(update?.availableRelease
        ? [{ label: update.canInstall ? `Install PR Master ${update.availableRelease.version}…` : `PR Master ${update.availableRelease.version} is available`, enabled: update.canInstall && !update.isInstalling, click: () => update.install() }]
        : []),
      { label: "Check for Updates…", click: () => checkForUpdates(true) },
      { label: "What's New", click: () => whatsNew.open() },
      { label: "Settings…", click: () => settingsWindow.open() },
      { type: "separator" },
      { label: "Quit", click: () => app.quit() },
    ]),
  );
}

if (!app.requestSingleInstanceLock()) app.quit();
app.on("second-instance", () => win && showWindow());

app.whenReady().then(async () => {
  app.setAppUserModelId("com.antoniovizuete.prmaster"); // required for toasts on Windows
  // A fresh install is spared the changelog: nothing was stored before this launch.
  const firstRun = fileStore("settings.json").read() === null;
  settings = createSettings(fileStore("settings.json"));
  secrets = withEnvFallback(createSecrets(userFile("secrets.json")));
  settings.onChange(applySetting);
  nativeTheme.themeSource = settings.get("theme");
  loadLocations();
  board = createBoardRuntime({ settings, secrets, getToken: readToken, notify: pushBoard });
  await board.init();

  tray = new Tray(icon(false));
  tray.setToolTip("PR Master");
  tray.on("click", showWindow);
  createWindow();
  settingsWindow = createSettingsWindow({ preload: here("./settingsPreload.cjs"), page: here("./settings/index.html"), settings, context: settingsContext, secrets, board });
  changelog = parseChangelog(fs.readFileSync(here("../CHANGELOG.md"), "utf8"));
  const shown = whatsNewEntries({ entries: changelog, current: app.getVersion(), lastSeen: settings.get("lastSeenVersion"), isFirstRun: firstRun });
  whatsNew = createWhatsNewWindow({
    preload: here("./whatsNewPreload.cjs"),
    page: here("./whatsnew/index.html"),
    entries: () => (shown.length ? shown : changelog.slice(0, 1)),
    onSeen: () => settings.set("lastSeenVersion", app.getVersion()),
  });
  rebuildTrayMenu();
  if (shown.length) whatsNew.open();
  else if (firstRun) settings.set("lastSeenVersion", app.getVersion());

  diffs = createDiffWindows({
    preload: here("./diffPreload.cjs"),
    page: here("./diff/index.html"),
    settings,
    secrets,
    // undefined until the first list has loaded; null once the PR left it.
    subjectOf: (kind, id) => (state.loaded ? ((kind === "own" ? state.prs : state.reviews).find((p) => p.id === id) ?? null) : undefined),
    onChanged: refresh,
  });

  ipcMain.on("review", (_e, kind, id) => diffs.open(kind, id));
  ipcMain.handle("state", viewState);
  ipcMain.on("refresh", refresh);
  ipcMain.on("act", (_e, kind, id) => act(kind, id));
  ipcMain.on("open-settings", () => settingsWindow.open());

  // ---- Board ----
  ipcMain.handle("board:state", () => board.view());
  ipcMain.on("board:move", (_e, id, lane) => board.move(id, lane));
  ipcMain.on("board:query", (_e, query) => board.setQuery(query));
  ipcMain.on("board:layout", (_e, layout) => (layout === "list" || layout === "board") && settings.set("boardLayout", layout));
  ipcMain.on("board:fields", (_e, values) => (values === null ? board.cancelFields() : board.submitFields(values ?? {})));
  ipcMain.on("board:dismiss", () => board.dismissMoveFailures());
  ipcMain.on("board:refresh", () => board.refreshAll());
  ipcMain.on("context", (_e, spec) => popUpContextMenu(spec));
  // The board layout draws a column per lane, so the window widens to fit them and narrows again, capped to the display.
  ipcMain.on("window:wide", (_e, wide) => {
    const [width, height] = win.getSize();
    const { workArea } = screen.getDisplayMatching(win.getBounds());
    const target = wide ? Math.min(1280, workArea.width) : 480;
    if (Math.abs(width - target) > 4) win.setSize(target, height);
  });
  ipcMain.on("open", (_e, url) => {
    if (url.startsWith("https://")) shell.openExternal(url); // CircleCI pipelines too
  });

  await refresh();
  board.refreshAll().then(pushBoard);
  powerMonitor.on("resume", () => {
    refresh();
    board.refreshAll();
  });
  if (process.env.PRMASTER_SELFTEST) {
    await runSelfTest({ win, tray, diffs, getState: () => state, viewState, settingsWindow, board, markQuitting: () => (quitting = true) });
    return;
  }
  setInterval(refresh, POLL_MS);
  board.startPolling();

  // ---- Updates and What's New ----
  update = new AppUpdate({
    currentVersion: app.getVersion(),
    checker: { latest: () => checkLatestRelease({ repo: releaseRepo() }) },
    // Installing replaces the running app: only an installed build may do it.
    installer: app.isPackaged ? createUpdateInstaller({ app }) : null,
  });
  update.onChange = () => {
    rebuildTrayMenu();
    if (win && !win.isDestroyed()) win.webContents.send("state", viewState());
  };
  ipcMain.on("update:install", () => update.install());
  setInterval(() => checkForUpdates(false), 30 * 60_000); // against a 60-per-hour unauthenticated budget
  checkForUpdates(false);
});

app.on("before-quit", () => (quitting = true));

// A tray app has no window to keep it alive.
app.on("window-all-closed", (e) => e.preventDefault());
