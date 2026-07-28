/// Decides which pull requests to bring up to date with their base branch.
///
/// Same shape as `NotificationDecider`, and for the same reason: the set of
/// already-attempted keys *is* the state, so there is no snapshot to diff and
/// nothing to reconcile at launch.
///
/// The key is `(id, head oid)` rather than the id alone, and that is the entire
/// loop protection. A refused update — a conflict, a protected branch, a lost
/// race — leaves the head oid exactly where it was, so the key stays recorded
/// and the app never asks again. A successful one moves the head, which retires
/// the old key naturally. Keying on the id alone would retry a doomed update
/// every poll; keying on nothing would push a commit a minute.
public enum BranchUpdateDecider {

    static func key(_ pr: PullRequest) -> String { "\(pr.id)@\(pr.headRefOid)" }

    /// - Parameters:
    ///   - prs: the PRs from a *successful* refresh. Never call this with stale
    ///     or partial data — it writes to GitHub.
    ///   - attempted: keys already tried. In-memory only: a relaunch is a fine
    ///     moment to give a previously refused update one more chance.
    /// - Returns: the PRs to update, and the set to carry forward.
    public static func decide(
        prs: [PullRequest],
        attempted: Set<String>
    ) -> (update: [PullRequest], updated: Set<String>) {
        // `.behind` is already the narrow set: `Readiness.evaluate` ranks draft
        // status, conflicts and check results above merge state, so none of
        // those can reach here. A PR is only behind once it is otherwise fine.
        let behind = prs.filter { $0.readiness == .behind }

        // Anything that stopped being behind, or left the list entirely, drops
        // out and is thereby re-armed for the next time base moves under it.
        return (
            update: behind.filter { !attempted.contains(key($0)) },
            updated: Set(behind.map(key))
        )
    }
}
