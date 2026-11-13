// Running Score over a whole diff: remembering answers, retrying what is worth
// retrying, giving up where it is hopeless, and drawing the result. The scoring
// part of DiffStore.swift and DiffRows.heatMarks.
import { diffBlocks, levelOfBlockScore, lineHeatOf } from "./score.js";

export const TOO_LARGE_MESSAGE = "Part of this file is too large to score.";

// What a score is remembered by: the same change in the same file.
const keyOf = (block) => `${block.key.path}\0${block.key.text}`;

// For each file with changed lines: scored at once when every block is remembered,
// otherwise waiting. A file with nothing changed has no entry.
export function prepareScoring(files, cache) {
  const blocks = new Map();
  const scores = new Map();
  const heat = new Map();
  for (const file of files) {
    const fileBlocks = diffBlocks(file);
    if (fileBlocks.length === 0) continue;
    blocks.set(file.path, fileBlocks);
    const cached = fileBlocks.map((b) => cache.get(keyOf(b)) ?? null);
    if (cached.every(Boolean)) {
      scores.set(file.path, cached);
      heat.set(file.path, { state: "scored", level: Math.max(...cached.map(levelOfBlockScore)) });
    } else {
      heat.set(file.path, { state: "waiting" });
    }
  }
  return { blocks, scores, heat };
}

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Scores every file that is still waiting, `concurrency` at a time. Reports each
// file through `onFile(path, { state, level, scores, message })`.
//
// - A rate limit is waited out as long as asked, then the same file is tried again.
// - A stumbling provider gets one more try; after that the file fails and the rest carry on.
// - A refused key or an empty account stops everything: every waiting file is told why.
// - Cancelling stops after the files already in flight.
export async function scoreFiles({ files, client, cache, concurrency = 4, retryDelayMs = 2000, sleep = defaultSleep, isCancelled = () => false, priorityPath = null, onFile, onStop }) {
  const prepared = prepareScoring(files, cache);
  const queue = files.map((f) => f.path).filter((p) => prepared.heat.get(p)?.state === "waiting");
  const at = priorityPath ? queue.indexOf(priorityPath) : -1;
  if (at > 0) queue.unshift(...queue.splice(at, 1));

  let stopped = false;

  const fail = (path, message) => onFile(path, { state: "failed", message });
  const stopAll = (current, message) => {
    if (stopped) return;
    stopped = true;
    for (const path of [current, ...queue.splice(0)]) fail(path, message);
    onStop?.(message);
  };

  async function scoreWithRetries(path, blocks) {
    let retried = false;
    for (;;) {
      try {
        return await client.score(path, blocks);
      } catch (e) {
        if (e?.code === "rateLimited") await sleep(e.retryAfterMs);
        else if (e?.code === "unavailable" && !retried) {
          retried = true;
          await sleep(retryDelayMs);
        } else throw e;
        if (isCancelled()) throw e;
      }
    }
  }

  async function worker() {
    while (!stopped && !isCancelled() && queue.length > 0) {
      const path = queue.shift();
      const blocks = prepared.blocks.get(path);
      try {
        const result = await scoreWithRetries(path, blocks);
        blocks.forEach((block, i) => result.blocks[i] && cache.set(keyOf(block), result.blocks[i]));
        if (result.tooLarge) onFile(path, { state: "failed", message: TOO_LARGE_MESSAGE, scores: result.blocks });
        else onFile(path, { state: "scored", level: Math.max(0, ...result.blocks.filter(Boolean).map(levelOfBlockScore)), scores: result.blocks });
      } catch (e) {
        if (e?.code === "unauthorized" || e?.code === "noCredits") stopAll(path, e.message);
        else fail(path, e?.message ?? "Scoring failed.");
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(concurrency, queue.length) }, worker));
}

// ---- Showing the scores -----------------------------------------------------

// Heat for each changed line, from the score of its block. The loaded diff is
// never written into: this returns a copy.
export function applyHeat(file, blockScores) {
  if (file.content.kind !== "hunks") return file;
  const hunks = file.content.hunks.map((h) => ({ ...h, lines: h.lines.map((l) => ({ ...l })) }));
  diffBlocks(file).forEach((block, i) => {
    const score = blockScores[i];
    if (!score) return;
    for (let offset = 0; offset < block.end - block.start; offset++) {
      hunks[block.hunk].lines[block.start + offset].heat = lineHeatOf(score, offset);
    }
  });
  return { ...file, content: { kind: "hunks", hunks } };
}

const levelOfRow = (row) => {
  if (row.type === "line") return row.line.heat?.level;
  if (row.type === "pair") return Math.max(row.left?.heat?.level ?? -1, row.right?.heat?.level ?? -1);
  return undefined;
};

// One mark per unbroken run of business logic or sensitive rows, at the run's
// start, as the hottest level inside it.
export function heatMarks(rows) {
  const marks = [];
  let start = null;
  let level = 0;
  const close = () => {
    if (start !== null) marks.push({ row: start, fraction: start / rows.length, level });
    start = null;
  };
  rows.forEach((row, index) => {
    const l = levelOfRow(row);
    if (l === undefined || l < 2) return close();
    if (start === null) {
      start = index;
      level = l;
    } else {
      level = Math.max(level, l);
    }
  });
  close();
  return marks;
}
