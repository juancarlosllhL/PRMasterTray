// Prints the changelog section for the version of $TAG (windows-v<version>), or nothing.
import fs from "node:fs";
import { notesFor } from "../src/core/release.js";

const version = (process.env.TAG ?? "").replace(/^windows-v/, "");
process.stdout.write(notesFor(fs.readFileSync(new URL("../CHANGELOG.md", import.meta.url), "utf8"), version));
