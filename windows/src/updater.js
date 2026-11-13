import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { verifyDigest } from "./core/appUpdate.js";

// Replaces the running app with a downloaded release. Lives here rather than in
// core because every step of it is untestable by construction: it writes to the
// filesystem, starts a process and ends this one. The parts that can be tested were
// pushed down into core: `verifyDigest` verifies the bytes, `AppUpdate` decides
// whether there is anything to install.
//
// download -> verify -> write -> run the installer silently -> exit. It refuses at
// the first step that does not hold rather than pressing on.
export function createUpdateInstaller({ app, fetchImpl = fetch }) {
  return {
    async install(release) {
      const res = await fetchImpl(release.assetURL, { headers: { "User-Agent": "PRMaster" }, redirect: "follow" });
      // GitHub redirects asset downloads to object storage; fetch follows that, so a
      // non-200 here is the final answer rather than the redirect.
      if (!res.ok) throw new Error(`the download returned ${res.status}`);
      const bytes = Buffer.from(await res.arrayBuffer());
      if (bytes.length === 0) throw new Error("the download was empty");

      // Before anything is written or run: an unsigned installer carries no
      // publisher, so the digest is the only thing that pins these bytes to the ones
      // our workflow uploaded.
      if (!verifyDigest(bytes, release.sha256)) throw new Error("The download did not match the checksum GitHub published for it, so it was not installed.");

      const work = fs.mkdtempSync(path.join(os.tmpdir(), "PRMasterUpdate-"));
      const installer = path.join(work, "PRMaster-Setup.exe");
      fs.writeFileSync(installer, bytes);

      // /S is NSIS's silent switch. The installer outlives this process, waits for it
      // to exit (it cannot replace files in use), installs and starts the new one.
      try {
        spawn(installer, ["/S"], { detached: true, stdio: "ignore" }).unref();
      } catch {
        throw new Error("the installer could not be started");
      }
      app.exit(0); // not app.quit(): nothing here is unsaved, and the files are about to be replaced
    },
  };
}
