import { BrowserWindow, ipcMain } from "electron";
import { DEFAULT_PATTERNS, SECONDARY } from "./core/fileScope.js";
import { GlobList } from "./core/glob.js";

// The settings window: one form, every change saved the moment it is made.
// `context()` is what only the poll knows (teams, organizations seen).
export function createSettingsWindow({ preload, page, settings, context, secrets, board }) {
  let win = null;

  // Patterns that would not compile are reported, never silently dropped.
  const invalidPatterns = () => {
    const patterns = settings.get("diffSectionPatterns") ?? DEFAULT_PATTERNS;
    return Object.fromEntries(SECONDARY.map((s) => [s, new GlobList(patterns[s] ?? []).invalidLines]));
  };

  const snapshot = () => ({
    values: settings.all(),
    context: { ...context(), defaultPatterns: DEFAULT_PATTERNS, invalidPatterns: invalidPatterns(), secrets: secretsState() },
  });

  const secretsState = () => ({ available: secrets?.available() ?? false, openRouterKey: secrets?.has("openrouter-key") ?? false });

  const push = () => win && !win.isDestroyed() && win.webContents.send("settings:changed", snapshot());

  ipcMain.handle("settings:all", snapshot);
  ipcMain.handle("settings:set", (_e, key, value) => {
    try {
      settings.set(key, value);
      return null;
    } catch (e) {
      return e.message;
    }
  });
  ipcMain.handle("settings:secret", (_e, name, value) => {
    if (name !== "openrouter-key") return "unknown secret";
    try {
      if (value) secrets.set(name, value);
      else secrets.delete(name);
      push();
      return null;
    } catch (e) {
      return e.message;
    }
  });
  // Board: the Jira sign-in and the GitHub boards. Errors come back as text for the form.
  const attempt = async (fn) => {
    try {
      await fn();
      push();
      return null;
    } catch (e) {
      return e.message;
    }
  };
  ipcMain.handle("board:signIn", (_e, input) => attempt(() => board.signInToJira(input)));
  ipcMain.handle("board:signOut", () => attempt(async () => board.signOutOfJira()));
  ipcMain.handle("board:discover", () => attempt(() => board.discoverProjects()));
  ipcMain.handle("board:projectShown", (_e, id, shown) => attempt(() => board.setProjectShown(String(id), Boolean(shown))));
  ipcMain.handle("board:projectChoice", (_e, project, option, choice) => attempt(async () => board.setProjectChoice(String(project), String(option), String(choice))));
  settings.onChange(push);

  return {
    open() {
      if (win && !win.isDestroyed()) {
        win.show();
        win.focus();
        return win;
      }
      win = new BrowserWindow({ width: 720, height: 760, title: "PR Master — Settings", autoHideMenuBar: true, webPreferences: { preload, contextIsolation: true } });
      win.loadFile(page);
      return win;
    },
    refresh: push,
    get window() {
      return win;
    },
  };
}
