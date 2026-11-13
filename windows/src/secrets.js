import { safeStorage } from "electron";
import fs from "node:fs";

// Credentials this app must remember (the OpenRouter key, Jira sign-in), encrypted
// with Windows' own per-user protection (DPAPI, via Electron's safeStorage) so the
// file is useless to anything not running as this user. The GitHub token is never
// stored here: it is borrowed from `gh` at each poll.
export function createSecrets(file) {
  const load = () => {
    try {
      return JSON.parse(fs.readFileSync(file, "utf8"));
    } catch {
      return {};
    }
  };
  const save = (all) => fs.writeFileSync(file, JSON.stringify(all));

  return {
    available: () => safeStorage.isEncryptionAvailable(),
    has: (name) => name in load(),
    get(name) {
      const stored = load()[name];
      if (stored === undefined) return null;
      try {
        return safeStorage.decryptString(Buffer.from(stored, "base64"));
      } catch {
        return null; // written by another user or machine: as good as absent
      }
    },
    set(name, value) {
      if (!safeStorage.isEncryptionAvailable()) throw new Error("Windows cannot encrypt secrets for this user right now");
      save({ ...load(), [name]: safeStorage.encryptString(value).toString("base64") });
    },
    delete(name) {
      const { [name]: _gone, ...rest } = load();
      save(rest);
    },
  };
}
