// Runs Shiki off the main thread: tokenising a large file takes long enough to
// freeze the windows if it ran beside them.
import { parentPort } from "node:worker_threads";
import { loadShiki } from "./core/highlight.js";

const shiki = loadShiki();

parentPort.on("message", ({ id, segments, language, theme }) => {
  try {
    parentPort.postMessage({ id, json: shiki.highlight(segments, language, theme) });
  } catch (e) {
    parentPort.postMessage({ id, error: e.message });
  }
});
