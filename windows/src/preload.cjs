const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("prmaster", {
  state: () => ipcRenderer.invoke("state"),
  onState: (cb) => ipcRenderer.on("state", (_e, s) => cb(s)),
  open: (url) => ipcRenderer.send("open", url),
  act: (kind, id) => ipcRenderer.send("act", kind, id),
  review: (kind, id) => ipcRenderer.send("review", kind, id),
  board: {
    state: () => ipcRenderer.invoke("board:state"),
    onState: (cb) => ipcRenderer.on("board", (_e, s) => cb(s)),
    move: (id, lane) => ipcRenderer.send("board:move", id, lane),
    setQuery: (query) => ipcRenderer.send("board:query", query),
    setLayout: (layout) => ipcRenderer.send("board:layout", layout),
    fields: (values) => ipcRenderer.send("board:fields", values),
    dismiss: () => ipcRenderer.send("board:dismiss"),
    refresh: () => ipcRenderer.send("board:refresh"),
  },
  contextMenu: (spec) => ipcRenderer.send("context", spec),
  installUpdate: () => ipcRenderer.send("update:install"),
  setWide: (wide) => ipcRenderer.send("window:wide", Boolean(wide)),
  openSettings: () => ipcRenderer.send("open-settings"),
  refresh: () => ipcRenderer.send("refresh"),
});
