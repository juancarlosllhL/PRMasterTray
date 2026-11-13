import { BrowserWindow, ipcMain } from "electron";

// "What's new": the changelog entries a launch has to show, said once. `entries`
// are as parsed by core/changelog.js; `onSeen` records that they were shown.
export function createWhatsNewWindow({ preload, page, entries, onSeen }) {
  let win = null;

  ipcMain.handle("whatsnew:entries", () => entries());

  return {
    open() {
      if (win && !win.isDestroyed()) {
        win.show();
        win.focus();
        return win;
      }
      win = new BrowserWindow({ width: 520, height: 600, title: "What's New in PR Master", autoHideMenuBar: true, webPreferences: { preload, contextIsolation: true } });
      win.loadFile(page);
      win.on("closed", () => {
        win = null;
        onSeen();
      });
      return win;
    },
  };
}
