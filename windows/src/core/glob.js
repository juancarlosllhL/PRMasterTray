// One `.gitignore`-style pattern, matched against a repository-relative path.
// Case-sensitive, like git. Also accepts `{a,b}`, which git does not.
// Port of Glob.swift.

export class GlobError extends Error {
  constructor(code) {
    super(code);
    this.code = code; // "empty" | "unbalancedBrace" | "unbalancedBracket"
  }
}

const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\/-]/g, "\\$&");

function translate(body) {
  const chars = [...body];
  let out = "";
  let braceDepth = 0;
  for (let i = 0; i < chars.length; i++) {
    const char = chars[i];
    const atSegmentStart = i === 0 || chars[i - 1] === "/";
    if (char === "*" && chars[i + 1] === "*" && atSegmentStart) {
      if (i + 2 === chars.length) {
        out += ".*";
        i += 1;
      } else if (chars[i + 2] === "/") {
        out += "(?:.*/)?";
        i += 2;
      } else {
        out += "[^/]*";
        i += 1;
      }
    } else if (char === "*") {
      out += "[^/]*";
    } else if (char === "?") {
      out += "[^/]";
    } else if (char === "[") {
      const close = chars.indexOf("]", i + 1);
      if (close < 0 || close === i + 1) throw new GlobError("unbalancedBracket");
      let set = chars.slice(i + 1, close).join("");
      if (set.startsWith("!")) set = `^${set.slice(1)}`;
      out += `[${set.replaceAll("\\", "\\\\")}]`;
      i = close;
    } else if (char === "{") {
      braceDepth++;
      out += "(?:";
    } else if (char === "}" && braceDepth > 0) {
      braceDepth--;
      out += ")";
    } else if (char === "," && braceDepth > 0) {
      out += "|";
    } else if (char === "\\" && i + 1 < chars.length) {
      i++;
      out += escapeRegex(chars[i]);
    } else {
      out += escapeRegex(char);
    }
  }
  if (braceDepth !== 0) throw new GlobError("unbalancedBrace");
  return out;
}

export function compileGlob(pattern) {
  let body = pattern;
  const negated = body.startsWith("!");
  if (negated) body = body.slice(1);
  const directoryOnly = body.endsWith("/");
  if (directoryOnly) body = body.slice(0, -1);
  const anchored = body.includes("/");
  if (body.startsWith("/")) body = body.slice(1);
  if (!body) throw new GlobError("empty");

  const prefix = anchored ? "^" : "^(?:.*/)?";
  const suffix = directoryOnly ? "/.*$" : "(?:/.*)?$";
  const regex = new RegExp(prefix + translate(body) + suffix);
  return { source: pattern, negated, matches: (path) => regex.test(path) };
}

// A list of patterns in settings order: blank lines and `#` comments are
// skipped, and the last pattern that matches decides, as in `.gitignore`.
export class GlobList {
  constructor(lines) {
    this.globs = [];
    this.invalidLines = [];
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      try {
        this.globs.push(compileGlob(trimmed));
      } catch (e) {
        if (!(e instanceof GlobError)) throw e;
        this.invalidLines.push(trimmed);
      }
    }
  }

  // true when included, false when a `!` rule re-included it, null when no rule applies.
  verdict(path) {
    const last = this.globs.findLast((g) => g.matches(path));
    return last ? !last.negated : null;
  }
}
