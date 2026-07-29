import Foundation
import PRMasterCore

/// Serves PRs from a local JSON file instead of GitHub.
///
/// Exists because the app's headline behaviour — a PR turning green and
/// notifying — is otherwise unverifiable on demand: it needs a real reviewer
/// to approve a real PR at the right moment. Set `PRMASTER_FIXTURE` to a
/// search-response JSON file to drive the UI deterministically.
///
/// Only fetching is faked. Merging always goes to the real API, so this can
/// never cause a merge that would not otherwise have happened.
struct FixtureClient: PullRequestFetching {
    let path: String

    func fetchMyPullRequests() async throws -> [PullRequest] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try PullRequestDecoder.decodeSearch(data)
    }
}

/// Always fails, so the error states can be inspected on demand.
struct FailingClient: PullRequestFetching {
    let error: PRMasterError
    func fetchMyPullRequests() async throws -> [PullRequest] { throw error }
}

/// Succeeds `successes` times then fails forever.
///
/// The stale banner is the app's subtlest state — real data plus a failed
/// refresh — and is otherwise only reachable by pulling the network cable at
/// exactly the right moment.
final class FlakyClient: PullRequestFetching, @unchecked Sendable {
    private let base: PullRequestFetching
    private let error: PRMasterError
    private let lock = NSLock()
    private var remaining: Int

    init(base: PullRequestFetching, successes: Int, error: PRMasterError) {
        self.base = base
        self.remaining = successes
        self.error = error
    }

    func fetchMyPullRequests() async throws -> [PullRequest] {
        let allowed = lock.withLock { () -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        guard allowed else { throw error }
        return try await base.fetchMyPullRequests()
    }
}

/// Accepts a merge and does nothing. Used only by PRMASTER_DEMO_MERGE, so the
/// confirmation dialog can be exercised without any call to GitHub.
struct NoopMerger: PullRequestMerging {
    func squashMerge(id: String, expectedHeadOid: String) async throws {}
}

enum Debug {
    /// Non-nil when `PRMASTER_FIXTURE` points at a readable file.
    static var fixturePath: String? {
        guard let path = ProcessInfo.processInfo.environment["PRMASTER_FIXTURE"],
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        return path
    }

    /// `PRMASTER_FAKE_ERROR=ghNotFound|notAuthenticated|network` forces a
    /// failure so the setup and stale-banner states are reachable without
    /// having to uninstall gh or pull the network cable.
    static var fakeError: PRMasterError? {
        switch ProcessInfo.processInfo.environment["PRMASTER_FAKE_ERROR"] {
        case "ghNotFound": return .ghNotFound
        case "notAuthenticated": return .notAuthenticated(detail: "forced")
        case "network": return .network(URLError(.notConnectedToInternet))
        default: return nil
        }
    }

    /// `PRMASTER_FAIL_AFTER=n` with a fixture: serve the fixture n times, then
    /// fail, so the stale banner becomes reachable.
    static var failAfter: Int? {
        ProcessInfo.processInfo.environment["PRMASTER_FAIL_AFTER"].flatMap(Int.init)
    }

    /// True when the app is showing anything other than live GitHub data.
    ///
    /// Merging is refused in this state. Fixtures are routinely captured from
    /// live API responses, so a fixture row can carry a real node ID and a real
    /// head oid — merging from one would merge a real pull request, and
    /// expectedHeadOid would not stop it because the oid is real too.
    static var overridesActive: Bool {
        fixturePath != nil || fakeError != nil || failAfter != nil || demoMerge != nil
    }

    /// `PRMASTER_AUTO_OPEN=1` opens the popover at launch, so the real-data
    /// path can be inspected without clicking the menu bar.
    static var autoOpen: Bool {
        ProcessInfo.processInfo.environment["PRMASTER_AUTO_OPEN"] == "1"
    }

    /// `PRMASTER_OPEN_SETTINGS=1` opens the settings window at launch. It is
    /// otherwise only reachable through the gear menu, which nothing but a real
    /// mouse can open — including whatever is taking the screenshots. Not part of
    /// `overridesActive`: it fakes no data, so it has no bearing on merging.
    static var openSettings: Bool {
        ProcessInfo.processInfo.environment["PRMASTER_OPEN_SETTINGS"] == "1"
    }

    /// `PRMASTER_DEMO_MERGE=confirm|fail` drives the merge dialogs directly,
    /// so the irreversible path can be inspected without a mergeable PR. Any
    /// other value swaps in the no-op merger without opening a dialog.
    static var demoMerge: String? {
        ProcessInfo.processInfo.environment["PRMASTER_DEMO_MERGE"]
    }

    /// Whether to offer the Merge affordances — the row button and the
    /// notification action.
    ///
    /// Normally the inverse of `overridesActive`, because a fixture row can name
    /// a real pull request and the merge would be refused. `PRMASTER_DEMO_MERGE`
    /// is the exception: it swaps in `NoopMerger`, so nothing can be merged and
    /// the affordances are both safe and the point. Without this, the one hook
    /// for demonstrating the merge path hid its own entry point.
    static var mergingOffered: Bool { !overridesActive || demoMerge != nil }
}
