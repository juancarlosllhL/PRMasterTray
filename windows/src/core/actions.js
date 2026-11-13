// The writes offered on a row of the list. `allowed` and `prompt` are pure; `run`
// is the GitHub mutation. Merge is pinned to the head commit of the snapshot the
// user actually saw.
import { closePullRequest, squashMerge } from "./github.js";

export const ACTIONS = {
  merge: {
    allowed: (row) => row.readiness === "ready",
    prompt: (row) => ({ message: `Squash-merge #${row.number}?`, detail: `${row.repo}\n${row.title}`, button: "Merge" }),
    run: (auth, pr) => squashMerge({ ...auth, id: pr.id, expectedHeadOid: pr.headRefOid }),
  },
  close: {
    allowed: (row) => row.stale,
    prompt: (row) => ({ message: `Close #${row.number} without merging?`, detail: `${row.repo}\n${row.title}`, button: "Close pull request" }),
    run: (auth, pr) => closePullRequest({ ...auth, id: pr.id }),
  },
};
