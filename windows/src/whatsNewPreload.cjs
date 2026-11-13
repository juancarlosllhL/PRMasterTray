const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("whatsNewApi", {
  entries: () => ipcRenderer.invoke("whatsnew:entries"),
});
