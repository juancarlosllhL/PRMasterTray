// Score: how closely a human must review each changed line, asked of TypeSafe's
// Jev model through OpenRouter's System One endpoint. Port of Importance.swift,
// DiffBlocks.swift, BlockScoring.swift, JevRequest.swift, JevClient.swift and
// OpenRouterEndpoint.swift.

// ---- Importance -------------------------------------------------------------

export const LEVEL_NAMES = ["glue", "routine", "logic", "sensitive"];

// The nearest of four levels. Uncertainty is drawn as hatching, so it is not folded in here.
export function importanceOf(score) {
  if (!Number.isFinite(score)) return 3;
  return Math.round(Math.min(Math.max(score, 0), 3));
}

const UNCERTAIN_BELOW = 0.35; // the bottom quarter of line confidences measured on real diffs

// One answer from Jev: where a line falls on the four levels, and how sure it is.
export function heat(score, confidence) {
  const clamped = Number.isFinite(score) ? Math.min(Math.max(score, 0), 3) : 3;
  return { score: clamped, confidence: confidence ?? null, level: importanceOf(clamped), uncertain: (confidence ?? 1) < UNCERTAIN_BELOW };
}

// By position among the block's changed lines; none takes the block's answer.
export function lineHeatOf(blockScore, index) {
  return blockScore.lines[index] ?? blockScore.block;
}

// The hottest line drawn, so the sidebar never undersells a file.
export function levelOfBlockScore({ block, lines }) {
  const own = lines.filter(Boolean);
  const drawn = own.length === lines.length && lines.length > 0 ? own : [...own, block];
  return Math.max(...drawn.map((h) => h.level));
}

// ---- Blocks -----------------------------------------------------------------

const CONTEXT_LINES = 3;

// An unbroken run of added and removed lines inside one hunk, with a little
// context either side. Context stops at the next change: that change is its own block.
export function diffBlocks(file) {
  if (file.content.kind !== "hunks") return [];
  return file.content.hunks.flatMap((hunk, index) => {
    const lines = hunk.lines;
    const blocks = [];
    let start = 0;
    while (start < lines.length) {
      if (lines[start].kind === "context") {
        start++;
        continue;
      }
      let end = start;
      while (end < lines.length && lines[end].kind !== "context") end++;
      const changed = lines.slice(start, end).map((l) => (l.kind === "added" ? "+" : "-") + l.text);
      const before = [];
      for (let i = start - 1; i >= Math.max(0, start - CONTEXT_LINES) && lines[i].kind === "context"; i--) before.unshift(lines[i].text);
      const after = [];
      for (let i = end; i < Math.min(lines.length, end + CONTEXT_LINES) && lines[i].kind === "context"; i++) after.push(lines[i].text);
      blocks.push({ hunk: index, start, end, key: { path: file.path, text: changed.join("\n") }, changed, before, after, declaration: hunk.context });
      start = end;
    }
    return blocks;
  });
}

// ---- The request ------------------------------------------------------------

const MODEL = "typesafe/jev-1.13";
const MAX_LINE_CHARACTERS = 500;
const CHARACTERS_PER_TOKEN = 3;
const BLOCK_QUESTION_TOKENS = 160;
const LINE_QUESTION_TOKENS = 110;
// Jev's limit for the state plus its longest question is 32,000; for a whole request about 65,000.
const MAX_STATE_TOKENS = 30_000;
const MAX_REQUEST_TOKENS = 60_000;
const PROVIDER = { data_collection: "deny" }; // changed lines are never kept by the provider

const CRITERIA = [
  "Glue: wiring, mapping between types, renames, imports, formatting, boilerplate",
  "Routine: plain logic whose effect is obvious from reading it",
  "Business logic: rules, calculations, conditions or state changes that decide what the product does",
  "Sensitive: authentication, permissions, money, deleting data, concurrency, migrations, secrets or input from outside",
];
const LINE_CRITERIA = ["Glue or boilerplate", "Routine logic", "Business logic", "Sensitive: security, secrets, data loss, concurrency"];

const tokens = (characters) => Math.ceil(characters / CHARACTERS_PER_TOKEN);
const blockKey = (index) => `b${index}`;
const lineKey = (index, offset) => `b${index}_l${offset}`;

// Blocks are named b<position> and their changed lines tagged [l<offset>], because
// Jev reads indexes and line numbers unreliably but follows a named key.
function render(block) {
  const out = [];
  if (block.declaration) out.push(`In ${block.declaration}`.slice(0, MAX_LINE_CHARACTERS));
  out.push(...block.before.map((l) => ` ${l}`.slice(0, MAX_LINE_CHARACTERS)));
  out.push(...block.changed.map((l, i) => `[l${i}] ${l.slice(0, MAX_LINE_CHARACTERS)}`));
  out.push(...block.after.map((l) => ` ${l}`.slice(0, MAX_LINE_CHARACTERS)));
  return out.join("\n");
}

// A line with no letter or digit, like a closing brace, says nothing on its own.
const askedLines = (block) => block.changed.map((l, i) => [l, i]).filter(([l]) => /[\p{L}\p{N}]/u.test(l.slice(1))).map(([, i]) => i);

function batchOf(path, entries) {
  const questions = {};
  for (const entry of entries) {
    const block = blockKey(entry.index);
    questions[block] = {
      type: "score",
      instructions: `How closely must a human review the change in \`blocks.${block}\`, all its lines together? Lines marked + were added and - removed. Judge what the code does, not what its comments claim.`,
      criteria: CRITERIA,
    };
    for (const offset of entry.lines) {
      questions[lineKey(entry.index, offset)] = {
        type: "score",
        instructions: `How closely must a human review the line tagged [l${offset}] in \`blocks.${block}\`, read with the rest of that block? Lines marked + were added and - removed. Judge what the code does, not what its comments claim.`,
        criteria: LINE_CRITERIA,
      };
    }
  }
  return {
    body: { model: MODEL, state: { path, blocks: Object.fromEntries(entries.map((e) => [blockKey(e.index), e.text])) }, questions, provider: PROVIDER },
    blocks: entries.map((e) => e.index),
    lines: Object.fromEntries(entries.map((e) => [e.index, e.lines])),
    lineCounts: Object.fromEntries(entries.map((e) => [e.index, e.lineCount])),
  };
}

export function jevBatches(path, blocks) {
  const batches = [];
  const tooLarge = [];
  let pending = [];
  let stateTokens = 0;
  let questionTokens = 0;
  const flush = () => {
    if (pending.length === 0) return;
    batches.push(batchOf(path, pending));
    pending = [];
    stateTokens = 0;
    questionTokens = 0;
  };

  blocks.forEach((block, index) => {
    const text = render(block);
    const entry = { index, text, lines: askedLines(block), lineCount: block.changed.length };
    const entryState = tokens(text.length);
    if (entryState + BLOCK_QUESTION_TOKENS > MAX_STATE_TOKENS) return void tooLarge.push(index);
    const entryQuestions = () => BLOCK_QUESTION_TOKENS + LINE_QUESTION_TOKENS * entry.lines.length;
    if (entryState + entryQuestions() > MAX_REQUEST_TOKENS) entry.lines = []; // ask about the block, not each line
    const fitsState = stateTokens + entryState + BLOCK_QUESTION_TOKENS <= MAX_STATE_TOKENS;
    const fitsRequest = stateTokens + questionTokens + entryState + entryQuestions() <= MAX_REQUEST_TOKENS;
    if (!(fitsState && fitsRequest)) flush();
    pending.push(entry);
    stateTokens += entryState;
    questionTokens += entryQuestions();
  });
  flush();
  return { batches, tooLarge };
}

// By block position; a block with no answer at all is absent.
export function jevScores(response, batch) {
  if (!response || typeof response.answers !== "object" || response.answers === null) throw new Error("response has no answers");
  const heatOf = (a) => (a && typeof a.score === "number" ? heat(a.score, a.confidence) : null);
  const scores = {};
  for (const index of batch.blocks) {
    const lines = Array.from({ length: batch.lineCounts[index] ?? 0 }, (_, offset) => heatOf(response.answers[lineKey(index, offset)]));
    const hottest = lines.filter(Boolean).reduce((best, h) => (!best || h.score > best.score ? h : best), null);
    const block = heatOf(response.answers[blockKey(index)]) ?? hottest;
    if (block) scores[index] = { block, lines };
  }
  return scores;
}

// ---- Where requests go ------------------------------------------------------

const DEFAULT_BASE = "https://openrouter.ai/api/v1";
const LOOPBACK = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);

// Blank means OpenRouter. The key is sent wherever this points, so nothing that
// could leak it passes.
export function parseEndpoint(raw) {
  const trimmed = raw.trim();
  let baseURL = DEFAULT_BASE;
  if (trimmed) {
    let url;
    try {
      url = new URL(trimmed);
    } catch {
      throw new Error("That isn't a URL. It should look like https://proxy.example/api/v1.");
    }
    if (!url.hostname) throw new Error("The URL needs a host, like https://proxy.example/api/v1.");
    const scheme = url.protocol.replace(":", "");
    if (!(scheme === "https" || (scheme === "http" && LOOPBACK.has(url.hostname.toLowerCase())))) throw new Error("Use https://. Plain http is allowed only for localhost.");
    if (url.username || url.password) throw new Error("Leave the user name and password out of the URL.");
    if (url.search || url.hash) throw new Error("Leave the query and the # part out of the URL.");
    baseURL = `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
  }
  return { baseURL, systemOne: `${baseURL}/systemone`, isDefault: baseURL === DEFAULT_BASE };
}

// ---- The client -------------------------------------------------------------

// code: unauthorized | noCredits | rateLimited | unavailable | refused
export class ScoreError extends Error {
  constructor(code, message, extra = {}) {
    super(message);
    this.code = code;
    Object.assign(this, extra);
  }
}

const FALLBACK_WAIT_MS = 10_000;

export const VERIFICATION = {
  model: MODEL,
  provider: PROVIDER,
  state: "PRMaster connection check",
  questions: { ok: { type: "noul", instructions: "Is `state` a connection check?", criteria: { true: "It is", false: "It is not" } } },
};

const isVerificationAnswer = (data) => data?.answers?.ok?.type === "noul" && typeof data.answers.ok.noul === "number";

export function createJevClient({ token, endpoint, fetchImpl = fetch }) {
  async function send(body) {
    let res;
    try {
      res = await fetchImpl(endpoint.systemOne, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "User-Agent": "PRMaster" },
        body: JSON.stringify(body),
      });
    } catch {
      throw new ScoreError("unavailable", "The scoring service could not be reached.");
    }
    if (res.status === 200) return res.json();
    if (res.status === 401 || res.status === 403) throw new ScoreError("unauthorized", "The OpenRouter key was refused.");
    if (res.status === 402) throw new ScoreError("noCredits", "The OpenRouter account has no credits left.");
    if (res.status === 429) {
      const seconds = Number(res.headers.get("retry-after"));
      throw new ScoreError("rateLimited", "Rate limited.", { retryAfterMs: Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : FALLBACK_WAIT_MS });
    }
    if (res.status >= 500) throw new ScoreError("unavailable", `The scoring service is unavailable (HTTP ${res.status}).`);
    throw new ScoreError("refused", `The scoring service refused the request (HTTP ${res.status}).`);
  }

  return {
    async score(path, blocks) {
      const { batches, tooLarge } = jevBatches(path, blocks);
      const scores = Array(blocks.length).fill(null);
      for (const batch of batches) {
        const data = await send(batch.body);
        let answers;
        try {
          answers = jevScores(data, batch);
        } catch {
          throw new ScoreError("refused", "The scoring service gave an unreadable answer.");
        }
        for (const [index, score] of Object.entries(answers)) scores[Number(index)] = score;
      }
      return { blocks: scores, tooLarge: tooLarge.length > 0 };
    },

    // One tiny question proves the key, the credits and access to the model at once.
    async verify() {
      if (!isVerificationAnswer(await send(VERIFICATION))) throw new ScoreError("refused", "not a Jev answer");
    },
  };
}
