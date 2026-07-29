import Foundation
import Observation

/// The subset of `GitHubClient` the store needs, so tests can stub it.
public protocol PullRequestFetching: Sendable {
    func fetchMyPullRequests() async throws -> [PullRequest]
}

extension GitHubClient: PullRequestFetching {}

/// Delivers a "ready to merge" notification. Implemented in the app target,
/// which keeps `PRMasterCore` free of AppKit.
///
/// Throwing matters: a swallowed delivery failure used to be permanent, because
/// the PR was recorded as notified regardless and only re-armed if it left the
/// ready state.
public protocol ReadyPRNotifying: Sendable {
    func notifyReady(_ pr: PullRequest) async throws
}

/// Persists which PRs have already been notified about, across launches.
public protocol NotifiedIDStore: Sendable {
    func load() -> Set<String>
    func save(_ ids: Set<String>)
}

/// The branch-update half of `GitHubClient`, so the store can be driven without
/// a network stack.
public protocol PullRequestBranchUpdating: Sendable {
    func updateBranch(id: String, expectedHeadOid: String) async throws
}

extension GitHubClient: PullRequestBranchUpdating {}

/// User-facing settings that outlive a launch.
public protocol PreferenceStoring: Sendable {
    func autoUpdateEnabled() -> Bool
    func setAutoUpdateEnabled(_ value: Bool)
    func filter() -> PRFilter
    func setFilter(_ value: PRFilter)
}

/// Observable state behind the menu bar UI.
@MainActor
@Observable
public final class PRStore {

    /// The last *successful* snapshot, as filtered. Deliberately not cleared on
    /// failure: a wifi blip must not make the app look like you have no open PRs.
    public private(set) var prs: [PullRequest] = []
    /// The same snapshot before `filter` ran. Kept so the settings window can
    /// offer organizations the user is currently hiding — deriving the list from
    /// the visible rows would make an organization disappear from the settings
    /// the moment it was switched off, with no way back.
    public private(set) var allPRs: [PullRequest] = []
    public private(set) var lastSuccessfulFetch: Date?
    public private(set) var lastError: PRMasterError?
    public private(set) var isRefreshing = false
    /// Set when a notification could not be delivered. The PR is retried on the
    /// next poll, but a persistent failure would otherwise be invisible — there
    /// is no logging in this app.
    public private(set) var lastNotificationFailure: String?
    /// Set when a branch update was refused. Surfaced for the same reason as
    /// `lastNotificationFailure`: the attempt is not retried while the head oid
    /// is unchanged, so a silent failure would leave the PR stuck behind its
    /// base branch with no explanation.
    public private(set) var lastUpdateFailure: String?
    /// PRs currently being brought up to date. This app writes to GitHub with
    /// no user gesture behind it, so it says so while it is happening.
    public private(set) var updatingIDs: Set<String> = []

    /// Whether behind PRs are brought up to date automatically. On by default;
    /// the switch exists because the alternative escape hatch is quitting.
    public var autoUpdateEnabled: Bool {
        didSet { preferences.setAutoUpdateEnabled(autoUpdateEnabled) }
    }

    /// Which pull requests the user wants to see. Writing to it re-derives the
    /// visible list from the snapshot already in hand, so the settings window
    /// takes effect immediately rather than at the next poll.
    public var filter: PRFilter {
        didSet {
            guard filter != oldValue else { return }
            preferences.setFilter(filter)
            prs = filter.apply(to: allPRs)
        }
    }

    /// Every organization the settings window should offer: the ones with open
    /// pull requests right now, plus the ones being hidden, which by definition
    /// have none showing. Sorted the way a person reads a list.
    public var knownOrganizations: [String] {
        Set(allPRs.map(\.organization))
            .union(filter.hiddenOrganizations)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// How many pull requests the filter is holding back. The popover shows this
    /// rather than letting a filtered-out list read as "you have no open PRs".
    public var hiddenCount: Int {
        allPRs.count - prs.count
    }

    public var readyCount: Int {
        prs.filter { $0.readiness == .ready }.count
    }

    /// 60s normally, stepping up while GitHub is unreachable so an offline
    /// laptop is not hammering the network every minute.
    private static let intervals: [Duration] = [.seconds(60), .seconds(120), .seconds(300)]

    private let client: PullRequestFetching
    private let notifier: ReadyPRNotifying
    private let idStore: NotifiedIDStore
    /// `nil` disables automatic updating outright. The app passes `nil` under
    /// any debug override, which is the only hard guarantee that a fixture row
    /// — which carries a real node ID and a real head oid — cannot cause a
    /// commit to be pushed to a real branch with nobody watching.
    private let updater: PullRequestBranchUpdating?
    private let preferences: PreferenceStoring
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private var notifiedIDs: Set<String>
    /// Deliberately not persisted: a relaunch is a reasonable moment to give a
    /// previously refused update one more chance.
    private var attemptedUpdates: Set<String> = []
    private var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?

    public init(
        client: PullRequestFetching,
        notifier: ReadyPRNotifying,
        idStore: NotifiedIDStore,
        updater: PullRequestBranchUpdating? = nil,
        preferences: PreferenceStoring = UserDefaultsPreferences(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.client = client
        self.notifier = notifier
        self.idStore = idStore
        self.updater = updater
        self.preferences = preferences
        self.now = now
        self.sleep = sleep
        self.notifiedIDs = idStore.load()
        self.autoUpdateEnabled = preferences.autoUpdateEnabled()
        self.filter = preferences.filter()
    }

    /// How long the loop will wait before the next refresh.
    var currentInterval: Duration {
        Self.intervals[min(consecutiveFailures, Self.intervals.count - 1)]
    }

    // MARK: - Refresh

    public func refresh() async {
        // Five call sites can reach here: the poll loop, opening the popover,
        // waking from sleep, finishing a merge, and the manual refresh button.
        // @MainActor methods are reentrant across `await`, so without this the
        // slower of two overlapping fetches wins and can restore stale data.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await client.fetchMyPullRequests()
            // Everything downstream sees the filtered list, deliberately: a
            // hidden PR must not notify, must not be updated on a timer, and
            // must not sit in the menu bar count. `allPRs` keeps the unfiltered
            // snapshot for the settings window and the hidden count.
            let fresh = filter.apply(to: fetched)

            // Only reached on success, which is what guarantees a network flap
            // cannot be mistaken for every PR going ready at once.
            let decision = NotificationDecider.decide(prs: fresh, notified: notifiedIDs)

            allPRs = fetched
            prs = fresh
            lastSuccessfulFetch = now()
            lastError = nil
            consecutiveFailures = 0

            var undelivered: Set<String> = []
            var failure: String?
            for pr in decision.notify {
                do {
                    try await notifier.notifyReady(pr)
                } catch {
                    // Leave the ID unrecorded so the next poll tries again.
                    undelivered.insert(pr.id)
                    failure = error.localizedDescription
                }
            }
            lastNotificationFailure = failure

            // Recorded only for PRs that actually posted. Previously-notified
            // IDs stay put; freshly-failed ones drop out and retry.
            notifiedIDs = decision.updated.subtracting(undelivered)
            idStore.save(notifiedIDs)

            // Only ever reached on a successful fetch, for the same reason the
            // notification decision is: a network flap must not look like every
            // PR falling behind at once.
            await updateBehindBranches(fresh)
        } catch {
            // `prs` and `lastSuccessfulFetch` are deliberately untouched.
            lastError = error as? PRMasterError ?? .decoding(String(describing: error))
            consecutiveFailures += 1
        }
    }

    // MARK: - Automatic branch update

    /// Merges the base branch into any PR that is behind it.
    ///
    /// Runs unattended off the poll loop, so every guard matters: a `nil`
    /// updater switches it off entirely, the preference switches it off at the
    /// user's request, and `BranchUpdateDecider` keys each attempt to the head
    /// oid so a refusal is never retried against an unchanged branch.
    private func updateBehindBranches(_ fresh: [PullRequest]) async {
        guard autoUpdateEnabled, let updater else {
            // Clear on the way out, or a warning about a refused update would
            // outlive the switch being turned off and go on describing
            // something the app is no longer even attempting.
            lastUpdateFailure = nil
            return
        }

        let decision = BranchUpdateDecider.decide(prs: fresh, attempted: attemptedUpdates)
        // Recorded before the attempt, not after: a crash or a cancellation
        // mid-flight must not leave the app free to push the same commit again.
        attemptedUpdates = decision.updated

        var failure: String?
        for pr in decision.update {
            updatingIDs.insert(pr.id)
            do {
                try await updater.updateBranch(id: pr.id, expectedHeadOid: pr.headRefOid)
            } catch {
                failure = error.localizedDescription
            }
            updatingIDs.remove(pr.id)
        }
        lastUpdateFailure = failure
    }

    // MARK: - Polling

    /// Refresh, wait, repeat. Exposed for tests so the loop can be driven with
    /// an injected sleep instead of real time.
    func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await sleep(currentInterval)
            } catch {
                return  // cancelled
            }
        }
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

/// `UserDefaults`-backed persistence. The token is never stored — only the
/// IDs of PRs already notified about.
public struct UserDefaultsIDStore: NotifiedIDStore {
    private let key = "notifiedPRIDs"
    // UserDefaults is documented as thread-safe but predates Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func save(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: key)
    }
}

/// `UserDefaults`-backed settings.
public struct UserDefaultsPreferences: PreferenceStoring {
    private let autoUpdateKey = "autoUpdateBehindBranches"
    private let hiddenOrganizationsKey = "hiddenOrganizations"
    private let showPrivateKey = "showPrivateRepositories"
    // UserDefaults is documented as thread-safe but predates Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func autoUpdateEnabled() -> Bool {
        // Probed through `object(forKey:)` because `bool(forKey:)` cannot tell
        // an absent key from a stored false, and would ship the feature
        // silently switched off for everyone who has never touched the setting.
        defaults.object(forKey: autoUpdateKey) as? Bool ?? true
    }

    public func setAutoUpdateEnabled(_ value: Bool) {
        defaults.set(value, forKey: autoUpdateKey)
    }

    public func filter() -> PRFilter {
        PRFilter(
            hiddenOrganizations: Set(defaults.stringArray(forKey: hiddenOrganizationsKey) ?? []),
            // Absent reads as shown, for the same reason as above: nobody's list
            // should get shorter because they installed an update.
            showsPrivateRepositories: defaults.object(forKey: showPrivateKey) as? Bool ?? true
        )
    }

    public func setFilter(_ value: PRFilter) {
        // Sorted so the stored array is stable and readable under
        // `defaults read com.jcll.PRMaster`, which is how this gets debugged.
        defaults.set(value.hiddenOrganizations.sorted(), forKey: hiddenOrganizationsKey)
        defaults.set(value.showsPrivateRepositories, forKey: showPrivateKey)
    }
}
