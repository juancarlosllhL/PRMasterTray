// Why a pull request can or cannot be merged right now. Port of
// Sources/PRMasterCore/Readiness.swift — keep the two in step.
//
// Order matters: the earlier a condition appears, the more it dominates.
export function evaluate(pr) {
  if (pr.isDraft) return "draft";
  if (pr.mergeable === "CONFLICTING") return "conflicted";

  switch (pr.checks) {
    case "FAILURE":
    case "ERROR":
      return "checksFailing";
    case "PENDING":
    case "EXPECTED":
      return "checksPending";
    // null means the repo has no CI at all; treating it as pending would leave
    // such PRs permanently unready.
  }

  switch (pr.mergeState) {
    case "CLEAN":
    case "UNSTABLE":
    case "HAS_HOOKS":
      return "ready";
    case "BEHIND":
      return "behind";
    case "BLOCKED":
    case "DIRTY": {
      // Quill first: its review lands before people look.
      const t = pr.threads;
      if (t && t.unresolvedByQuill > 0) return "quillComments";
      if (t && t.unresolved - t.unresolvedByQuill > 0) return "unresolvedComments";
      return "blocked";
    }
    default:
      // UNKNOWN: GitHub is still computing mergeability, which happens right
      // after every push. Calling this ready would notify on each one.
      return "checksPending";
  }
}
