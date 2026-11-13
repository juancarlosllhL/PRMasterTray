// Fails unless the tag in $TAG is windows-v<package.json version>. The tag arrives
// through the environment, never through a command line, so it is never expanded.
import fs from "node:fs";
import { tagMatchesVersion } from "../src/core/release.js";

const { version } = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const tag = process.env.TAG ?? "";
if (!tagMatchesVersion(tag, version)) {
  console.error(`tag '${tag}' does not match 'windows-v${version}' from package.json`);
  console.error(`bump the version in package.json, or tag windows-v${version} instead.`);
  process.exit(1);
}
console.log(`tag ${tag} matches package.json`);
