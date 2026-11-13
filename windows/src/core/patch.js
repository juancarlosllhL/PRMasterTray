// Reads the `patch` GitHub returns per file into numbered hunks. Port of
// PatchParser.swift.
//
// Driven by the counts in each header, the way `git apply` reads a patch, so a
// patch that disagrees with its own header is refused instead of misnumbered.

// `@@ -oldStart[,oldCount] +newStart[,newCount] @@[ context]`
function parseHeader(line) {
  const match = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: ?(.*))?$/);
  if (!match) throw new Error(`malformed header: ${line}`);
  const [, oldStart, oldCount, newStart, newCount, context] = match;
  return {
    oldStart: Number(oldStart),
    oldCount: oldCount === undefined ? 1 : Number(oldCount),
    newStart: Number(newStart),
    newCount: newCount === undefined ? 1 : Number(newCount),
    context: context ?? "",
  };
}

export function parseHunks(patch) {
  const lines = patch.split("\n").map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l));
  if (lines.at(-1) === "") lines.pop();

  const hunks = [];
  let index = 0;
  while (index < lines.length) {
    const header = parseHeader(lines[index++]);
    const body = [];
    let oldNumber = header.oldStart;
    let newNumber = header.newStart;
    let oldLeft = header.oldCount;
    let newLeft = header.newCount;

    // A "\ No newline" marker can follow the last counted line, so it is read even when both counts are spent.
    while (oldLeft > 0 || newLeft > 0 || lines[index]?.startsWith("\\")) {
      if (index >= lines.length) throw new Error("truncated hunk");
      const line = lines[index++];
      const marker = line[0]; // undefined for a blank line whose leading space was lost
      const text = line.slice(1);
      if (marker === "\\") {
        const last = body.at(-1);
        if (!last) throw new Error(`unexpected line: ${line}`);
        last.noNewlineAtEnd = true;
      } else if (marker === "-" && oldLeft > 0) {
        body.push({ kind: "removed", oldNumber: oldNumber++, newNumber: null, text, noNewlineAtEnd: false });
        oldLeft--;
      } else if (marker === "+" && newLeft > 0) {
        body.push({ kind: "added", oldNumber: null, newNumber: newNumber++, text, noNewlineAtEnd: false });
        newLeft--;
      } else if ((marker === " " || marker === undefined) && oldLeft > 0 && newLeft > 0) {
        body.push({ kind: "context", oldNumber: oldNumber++, newNumber: newNumber++, text, noNewlineAtEnd: false });
        oldLeft--;
        newLeft--;
      } else {
        throw new Error(`unexpected line: ${line}`);
      }
    }
    hunks.push({ ...header, lines: body });
  }
  return hunks;
}
