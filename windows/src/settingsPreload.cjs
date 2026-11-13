const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("settingsApi", {
  all: () => ipcRenderer.invoke("settings:all"),
  set: (key, value) => ipcRenderer.invoke("settings:set", key, value),
  setSecret: (name, value) => ipcRenderer.invoke("settings:secret", name, value),
  board: {
    signIn: (input) => ipcRenderer.invoke("board:signIn", input),
    signOut: () => ipcRenderer.invoke("board:signOut"),
    discover: () => ipcRenderer.invoke("board:discover"),
    projectShown: (id, shown) => ipcRenderer.invoke("board:projectShown", id, shown),
    projectChoice: (project, option, choice) => ipcRenderer.invoke("board:projectChoice", project, option, choice),
  },
  onChanged: (cb) => ipcRenderer.on("settings:changed", (_e, s) => cb(s)),
});
