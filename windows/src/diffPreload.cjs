const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("diffApi", {
  state: () => ipcRenderer.invoke("diff:state"),
  onState: (cb) => ipcRenderer.on("diff:state", (_e, s) => cb(s)),
  reload: () => ipcRenderer.send("diff:reload"),
  setViewed: (path, viewed) => ipcRenderer.send("diff:viewed", path, viewed),
  toggle: (path) => ipcRenderer.send("diff:toggle", path),
  setLayout: (layout) => ipcRenderer.send("diff:layout", layout),
  find: (query) => ipcRenderer.send("diff:find", query),
  findStep: (direction) => ipcRenderer.send("diff:findStep", direction),
  openLink: (url) => ipcRenderer.send("diff:openLink", url),
  score: () => ipcRenderer.send("diff:score"),
  prioritise: (path) => ipcRenderer.send("diff:prioritise", path),
  merge: () => ipcRenderer.send("diff:merge"),
  approve: () => ipcRenderer.send("diff:approve"),
});
