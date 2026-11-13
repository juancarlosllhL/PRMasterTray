// Syntax colour for diff lines, from the bundled Shiki script (the same
// resources/shiki.js the macOS app runs in JavaScriptCore). Port of
// SyntaxHighlighting.swift and ShikiHighlighter.swift.
import fs from "node:fs";
import vm from "node:vm";

const BY_FILE_NAME = {
  Dockerfile: "docker", Containerfile: "docker",
  Makefile: "make", makefile: "make", GNUmakefile: "make",
  Gemfile: "ruby", Rakefile: "ruby", Podfile: "ruby",
};

const BY_EXTENSION = {
  swift: "swift", go: "go",
  ts: "typescript", mts: "typescript", cts: "typescript", tsx: "tsx",
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  cs: "csharp", py: "python", json: "json", yml: "yaml", yaml: "yaml",
  sh: "shellscript", bash: "shellscript", zsh: "shellscript",
  md: "markdown", markdown: "markdown", html: "html", htm: "html", css: "css",
  sql: "sql", rs: "rust", java: "java", kt: "kotlin", kts: "kotlin",
  dockerfile: "docker", toml: "toml", tf: "hcl", tfvars: "hcl", hcl: "hcl",
  xml: "xml", plist: "xml", csproj: "xml", svg: "xml", rb: "ruby",
  c: "cpp", h: "cpp", cc: "cpp", cpp: "cpp", cxx: "cpp", hpp: "cpp", hh: "cpp",
  graphql: "graphql", gql: "graphql", graphqls: "graphql", mk: "make",
};

export function languageForPath(path) {
  const name = path.split("/").pop();
  if (BY_FILE_NAME[name]) return BY_FILE_NAME[name];
  const dot = name.lastIndexOf(".");
  return dot < 0 ? null : (BY_EXTENSION[name.slice(dot + 1).toLowerCase()] ?? null);
}

// A hunk read as the two files it comes from, so each side is tokenised as the
// code it really is: an old line is never coloured by the new side's context.
export function hunkSides(hunk) {
  const oldIndices = [];
  const newIndices = [];
  hunk.lines.forEach((l, i) => {
    if (l.kind !== "added") oldIndices.push(i);
    if (l.kind !== "removed") newIndices.push(i);
  });
  return {
    oldIndices,
    newIndices,
    oldTexts: oldIndices.map((i) => hunk.lines[i].text),
    newTexts: newIndices.map((i) => hunk.lines[i].text),
  };
}

const STYLE = { italic: 1, bold: 2, underline: 4 };
const plain = (text) => ({ text, colour: null, italic: false, bold: false, underline: false });

// Spans that tile the whole line. Tokens outside it are ignored rather than trusted.
export function tokensToSpans(text, tokens) {
  const valid = tokens
    .filter((t) => t.start >= 0 && t.end > t.start && t.end <= text.length)
    .sort((a, b) => a.start - b.start);
  const spans = [];
  let at = 0;
  for (const t of valid) {
    if (t.start < at) continue; // overlapping tokens: the first wins
    if (t.start > at) spans.push(plain(text.slice(at, t.start)));
    spans.push({
      text: text.slice(t.start, t.end),
      colour: t.colour,
      italic: Boolean(t.style & STYLE.italic),
      bold: Boolean(t.style & STYLE.bold),
      underline: Boolean(t.style & STYLE.underline),
    });
    at = t.end;
  }
  if (at < text.length) spans.push(plain(text.slice(at)));
  return spans.length ? spans : [plain(text)];
}

// Shiki answers each line as a flat [location, length, colourIndex, style, ...].
function decode(flat, colours, text) {
  const tokens = [];
  for (let i = 0; i + 3 < flat.length; i += 4) {
    const [start, length, colourIndex, style] = flat.slice(i, i + 4);
    const colour = colours[colourIndex];
    if (start < 0 || length <= 0 || start + length > text.length || !colour) continue;
    tokens.push({ start, end: start + length, colour, style });
  }
  return tokens;
}

// `highlight(segments, language, theme)` returns Shiki's JSON string. The file
// comes back unchanged when the language is unknown or anything about the answer
// is out of shape: losing the colour must never cost the diff.
export async function highlightFile(file, theme, highlight) {
  if (file.content.kind !== "hunks") return file;
  const language = languageForPath(file.path);
  if (!language) return file;

  const hunks = file.content.hunks;
  const sides = hunks.map(hunkSides);
  const segments = sides.flatMap((s) => [s.oldTexts, s.newTexts]);

  let payload;
  try {
    payload = JSON.parse(await highlight(segments, language, theme));
  } catch {
    return file;
  }
  if (!payload?.colours || payload.segments?.length !== segments.length) return file;
  // Every segment must come back with one range list per line.
  if (!segments.every((texts, i) => payload.segments[i] && payload.segments[i].length === texts.length)) return file;

  const highlighted = hunks.map((hunk, h) => {
    const lines = hunk.lines.map((l) => ({ ...l }));
    const apply = (indices, texts, flats, only) => {
      indices.forEach((index, position) => {
        if (only && lines[index].kind !== only) return;
        lines[index].spans = tokensToSpans(texts[position], decode(flats[position], payload.colours, texts[position]));
      });
    };
    apply(sides[h].oldIndices, sides[h].oldTexts, payload.segments[h * 2], "removed");
    apply(sides[h].newIndices, sides[h].newTexts, payload.segments[h * 2 + 1], null);
    return { ...hunk, lines };
  });
  return { ...file, content: { kind: "hunks", hunks: highlighted } };
}

// Runs the bundled script in its own context, which defines `prmaster`.
export function loadShiki(scriptPath = new URL("../../resources/shiki.js", import.meta.url)) {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync(scriptPath, "utf8"), context);
  const entry = context.prmaster;
  if (typeof entry?.highlight !== "function") throw new Error("shiki.js has no prmaster.highlight entry point");
  return {
    highlight: (segments, language, theme) => entry.highlight(segments, language, theme),
    languages: () => [...entry.languages()],
    themeColours: (theme) => [...entry.themeColours(theme)],
  };
}
