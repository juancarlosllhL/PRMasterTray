import { execFile } from "node:child_process";

// Windows installer's default location; a GUI app launched from the Start menu
// may not see a PATH edited after login.
const FALLBACK = "C:\\Program Files\\GitHub CLI\\gh.exe";

// Stdout is the token on success and may hold fragments on failure, so only the
// exit code ever reaches an error message. Stderr is discarded: gh writes
// advisory notices there.
export function runGh(binary) {
  return new Promise((resolve, reject) => {
    execFile(binary, ["auth", "token"], { windowsHide: true }, (err, stdout) => {
      if (err && typeof err.code !== "number") return reject(err);
      resolve({ stdout, exitCode: err ? err.code : 0 });
    });
  });
}

// PRMaster stores no credential of its own: the token is borrowed from `gh`.
export async function readToken({ run = runGh } = {}) {
  let result;
  try {
    result = await run("gh");
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
    try {
      result = await run(FALLBACK);
    } catch {
      throw new Error("GitHub CLI (gh) not found. Install it and run `gh auth login`.");
    }
  }
  if (result.exitCode !== 0) {
    throw new Error(`gh auth token exited with code ${result.exitCode}`);
  }
  const token = result.stdout.trim();
  if (!token) throw new Error("gh auth token returned no output");
  return token;
}
