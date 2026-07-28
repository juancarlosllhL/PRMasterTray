/// Decides which pull requests deserve a notification.
///
/// The set of already-notified IDs *is* the state — there is no snapshot diff.
/// That falls out nicely: a PR that became ready while the app was closed has
/// no previous snapshot to compare against, but it also has no recorded ID, so
/// it notifies on the next launch without any special cold-start handling.
public enum NotificationDecider {

    /// - Parameters:
    ///   - prs: the PRs from a *successful* refresh. Never call this with stale
    ///     or partial data: a failed fetch would look like everything at once.
    ///   - notified: IDs already notified about, persisted across launches.
    /// - Returns: the PRs to notify about, and the set to persist.
    public static func decide(
        prs: [PullRequest],
        notified: Set<String>
    ) -> (notify: [PullRequest], updated: Set<String>) {
        let ready = prs.filter { $0.readiness == .ready }

        // The new state is exactly the currently-ready IDs. Anything that
        // stopped being ready, or vanished from the list entirely, drops out
        // and is thereby re-armed — which is what makes a PR notify again
        // after a new commit knocks it out of ready and CI brings it back.
        return (
            notify: ready.filter { !notified.contains($0.id) },
            updated: Set(ready.map(\.id))
        )
    }
}
