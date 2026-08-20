import Foundation
import Observation

/// The subset of `GitHubClient` the store needs, so tests can stub it.
public protocol PullRequestFetching: Sendable {
    func fetchMyPullRequests(mergedWindow: MergedWindow) async throws -> PullRequestSnapshot
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

/// The two lookups that turn merged pull requests into shipments. Separate from
/// `PullRequestFetching` because they fail separately, and their failure must
/// not be allowed to look like the list failing.
public protocol ShipmentFetching: Sendable {
    func fetchReleases(repoIDs: [String], depth: Int) async throws -> [String: [Release]]
    func resolveContainment(_ candidates: [ContainmentCandidate]) async throws -> [ContainmentKey: Bool]
}

extension GitHubClient: ShipmentFetching {}

/// Reading which version each environment is running, out of the deployments
/// repositories Kargo promotes into.
///
/// Split from `ShipmentFetching` for the same reason that one is split from
/// `PullRequestFetching`: a deployments lookup failing must be reportable
/// without taking the merged rows down with it.
public protocol DeploymentFetching: Sendable {
    /// The app folders that a service repository ships into, or an empty array
    /// when it ships into none that can be found.
    func discover(repo: String) async throws -> [AppLocation]
    /// Every region's promoted version, per app folder.
    func promotions(for locations: [AppLocation]) async throws -> [AppLocation: [PromotedVersion]]
    /// The release each promoted version names, keyed by repository node ID, for
    /// the versions the release lookup's depth did not reach.
    func releases(forTags requests: [ReleaseTagRequest]) async throws -> [String: [Release]]
}

extension GitHubClient: DeploymentFetching {}

/// User-facing settings that outlive a launch.
public protocol PreferenceStoring: Sendable {
    func autoUpdateEnabled() -> Bool
    func setAutoUpdateEnabled(_ value: Bool)
    func filter() -> PRFilter
    func setFilter(_ value: PRFilter)
    func theme() -> AppTheme
    func setTheme(_ value: AppTheme)
    func monochromeEnabled() -> Bool
    func setMonochromeEnabled(_ value: Bool)
    func popoverBackground() -> PopoverBackground
    func setPopoverBackground(_ value: PopoverBackground)
    func staleThreshold() -> StaleThreshold
    func setStaleThreshold(_ value: StaleThreshold)
    func mergedWindow() -> MergedWindow
    func setMergedWindow(_ value: MergedWindow)
    /// Discovered app folders, keyed by service repository. An empty array is a
    /// real answer — that repository was searched and deploys nothing findable —
    /// so it is stored rather than retried on every poll.
    func appLocations() -> [String: [AppLocation]]
    func setAppLocations(_ value: [String: [AppLocation]])
    /// Whether the user asked for the app to open at login. Not whether it will —
    /// macOS owns that, and `LaunchAtLoginStore` reads it from there. This records
    /// the intent, which is the only thing that can tell a registration lost to an
    /// update from one nobody ever wanted.
    func launchAtLoginRequested() -> Bool
    func setLaunchAtLoginRequested(_ value: Bool)
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
    /// What became of the pull requests merged inside the retention window.
    ///
    /// Kept through a failed refresh for the same reason `prs` is: a wifi blip
    /// must not read as "nothing shipped today".
    public private(set) var shipments: [Shipment] = []
    /// Set when the release or containment lookup failed. Its own field rather
    /// than `lastError`, which drives the stale banner over the whole list —
    /// the open pull requests refreshed fine and must not be reported as stale
    /// because a version lookup did not.
    public private(set) var lastShipmentFailure: String?
    /// Set when the deployments lookup failed. Its own field again, and for the
    /// same reason: not knowing which environment is running a version says
    /// nothing about whether the version itself is right.
    public private(set) var lastDeploymentFailure: String?
    /// Whether a deployments lookup is in flight, so a row with no chips yet can
    /// say it is still looking rather than reading as a repository that deploys
    /// nowhere — which is what the two look like otherwise.
    public private(set) var isLoadingDeployments = false

    /// Whether behind PRs are brought up to date automatically. On by default;
    /// the switch exists because the alternative escape hatch is quitting.
    public var autoUpdateEnabled: Bool {
        didSet { preferences.setAutoUpdateEnabled(autoUpdateEnabled) }
    }

    /// How long a pull request may stay open before the list marks it.
    ///
    /// Read live by the rows rather than snapshotted into the store, which is what
    /// lets the picker re-mark the visible list on the spot: there is no derived
    /// state here to recompute, so unlike `filter` this setter only has to persist.
    public var staleThreshold: StaleThreshold {
        didSet { preferences.setStaleThreshold(staleThreshold) }
    }

    /// How far back the merged section reaches.
    ///
    /// Unlike `staleThreshold`, this one cannot be answered from the snapshot in
    /// hand: widening it asks for merges the last search never requested. So it
    /// persists and then kicks a refresh, rather than re-deriving in place and
    /// showing a wider window with nothing new in it.
    public var mergedWindow: MergedWindow {
        didSet {
            guard mergedWindow != oldValue else { return }
            preferences.setMergedWindow(mergedWindow)
            // Emptied on the spot. Waiting for a round trip to clear a section
            // the user just switched off reads as the switch not working.
            if mergedWindow == .off {
                cancelPromotionRefresh()
                shipments = []
                lastShipmentFailure = nil
                lastDeploymentFailure = nil
            }
            Task { await refresh() }
        }
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
    /// `nil` under a debug override, where there is no live client to ask. The
    /// merged rows still resolve from their own checks; they just carry no
    /// version.
    private let shipmentClient: ShipmentFetching?
    /// `nil` under a debug override, and whenever there is no live client to ask.
    /// The merged rows still carry their version; they just say nothing about
    /// which environment is running it.
    private let deploymentClient: DeploymentFetching?
    private let preferences: PreferenceStoring
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private var notifiedIDs: Set<String>
    /// Deliberately not persisted: a relaunch is a reasonable moment to give a
    /// previously refused update one more chance.
    private var attemptedUpdates: Set<String> = []
    /// Containment answers already obtained, so a shipment resolved to a
    /// version is never asked about again. Pruned to the visible merges each
    /// poll, or it would grow for as long as the app runs.
    private var containmentAnswers: [ContainmentKey: Bool] = [:]
    /// Discovered app folders per repository, loaded once and written back as
    /// repositories are searched. Searching costs a code-search call, which is
    /// rate-limited to roughly ten a minute, so it happens once per repository
    /// and never again — including when the answer was "none".
    private var appLocations: [String: [AppLocation]]
    /// Promoted versions per repository, replaced only on a successful lookup:
    /// yesterday's answer beats no answer, the same rule `shipments` follows.
    private var promotions: [String: [PromotedVersion]] = [:]
    /// The inputs the visible shipments were built from, kept so the chips can be
    /// folded in when the deployments lookup finishes without waiting for the
    /// next poll to re-derive everything.
    private var resolvedMerged: [MergedPullRequest] = []
    private var resolvedReleases: [String: [Release]] = [:]
    /// The deployments lookup in flight, if any. At most one: on a cold cache it
    /// takes a code search plus a read per hit, which is longer than the poll
    /// interval, and queuing them would spend a rate-limited search every poll.
    private var promotionTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?

    public init(
        client: PullRequestFetching,
        notifier: ReadyPRNotifying,
        idStore: NotifiedIDStore,
        updater: PullRequestBranchUpdating? = nil,
        shipmentClient: ShipmentFetching? = nil,
        deploymentClient: DeploymentFetching? = nil,
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
        self.shipmentClient = shipmentClient
        self.deploymentClient = deploymentClient
        self.preferences = preferences
        self.appLocations = preferences.appLocations()
        self.now = now
        self.sleep = sleep
        self.notifiedIDs = idStore.load()
        self.autoUpdateEnabled = preferences.autoUpdateEnabled()
        self.filter = preferences.filter()
        self.staleThreshold = preferences.staleThreshold()
        self.mergedWindow = preferences.mergedWindow()
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

        var freshMerged: [MergedPullRequest]?

        do {
            let fetched = try await client.fetchMyPullRequests(mergedWindow: mergedWindow)
            // Everything downstream sees the filtered list, deliberately: a
            // hidden PR must not notify, must not be updated on a timer, and
            // must not sit in the menu bar count. `allPRs` keeps the unfiltered
            // snapshot for the settings window and the hidden count.
            let fresh = filter.apply(to: fetched.open)
            // Hidden means hidden after the merge too, and the window is the
            // same one the query asked for.
            freshMerged = mergedWindow.recent(filter.apply(to: fetched.merged), now: now())

            // Only reached on success, which is what guarantees a network flap
            // cannot be mistaken for every PR going ready at once.
            let decision = NotificationDecider.decide(prs: fresh, notified: notifiedIDs)

            allPRs = fetched.open
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

        // Deliberately outside the block above. These two lookups fail on their
        // own account, and a failed version lookup must leave `prs`,
        // `lastError` and the stale banner exactly as the search left them.
        // `freshMerged` is nil only when the search itself failed, in which case
        // the previous shipments stand.
        if let freshMerged {
            await resolveShipments(freshMerged)
        }
    }

    // MARK: - Shipments

    /// Turns the merged pull requests into shipments, asking GitHub only about
    /// the releases it has not already answered for.
    private func resolveShipments(_ merged: [MergedPullRequest]) async {
        // Nothing in view — the window is off, or everything aged out. The
        // section empties, and no request goes out to establish that. Relying on
        // the client's own empty guard would work but would leave the intent
        // living in the adapter rather than in the decision.
        guard !merged.isEmpty else {
            cancelPromotionRefresh()
            shipments = []
            lastShipmentFailure = nil
            lastDeploymentFailure = nil
            promotions = [:]
            resolvedMerged = []
            resolvedReleases = [:]
            return
        }

        // Deliberately not awaited. The deployments lookup is the slow half —
        // on a cold cache it is a code search plus a read per hit — and making
        // the list wait for it left the popover empty for seconds to say
        // something the rows do not depend on. It folds its answer in when it
        // arrives.
        defer { startPromotionRefresh(for: merged) }

        guard let shipmentClient else {
            // No live client: the rows still say whether CI passed, from the
            // checks already in hand. They just never carry a version.
            resolvedMerged = merged
            resolvedReleases = [:]
            rebuildShipments()
            return
        }

        // Answers about pull requests that have aged out are dropped, so this
        // cannot grow without bound.
        let live = Set(merged.map(\.id))
        containmentAnswers = containmentAnswers.filter { live.contains($0.key.pullRequestID) }

        do {
            let repoIDs = Array(Set(merged.map(\.repositoryID)))
            let releases = try await shipmentClient.fetchReleases(
                repoIDs: repoIDs, depth: mergedWindow.releaseDepth
            )

            // Only the unanswered ones: a shipment already resolved to a version
            // would otherwise be re-compared on every poll for a day.
            let unanswered = ShipmentResolver
                .candidates(merged: merged, releases: releases)
                .filter { containmentAnswers[$0.key] == nil }

            let answers = try await shipmentClient.resolveContainment(unanswered)
            containmentAnswers.merge(answers) { _, new in new }

            resolvedMerged = merged
            resolvedReleases = releases
            rebuildShipments()
            lastShipmentFailure = nil
        } catch {
            // `shipments` is left alone: yesterday's answer beats no answer.
            lastShipmentFailure = error.localizedDescription
        }
    }

    /// Rebuilds the visible rows from the last good snapshot.
    ///
    /// Called both when the release lookup lands and, later, when the
    /// deployments lookup does — so chips appear on their own rather than on
    /// the next poll.
    private func rebuildShipments() {
        guard !resolvedMerged.isEmpty else { return }
        shipments = ShipmentResolver.resolve(
            merged: resolvedMerged,
            releases: resolvedReleases,
            containment: containmentAnswers,
            promotions: promotions
        )
    }

    // MARK: - Deployments

    /// Reads what each environment is running, for the repositories in view.
    ///
    /// Kept apart from the release lookup above so the two fail independently: a
    /// deployments repository being unreachable must still leave a row saying
    /// which version was cut, and `promotions` is replaced only on success so a
    /// flap does not blank chips that were right a minute ago.
    /// Starts a lookup unless one is already running.
    ///
    /// Skipped rather than queued while one is in flight: a cold discovery
    /// outlasts the poll interval, and stacking them would spend a rate-limited
    /// code search per poll to learn the same thing.
    private func startPromotionRefresh(for merged: [MergedPullRequest]) {
        guard deploymentClient != nil, promotionTask == nil else { return }
        isLoadingDeployments = true
        promotionTask = Task { [weak self] in
            await self?.refreshPromotions(for: merged)
            self?.promotionTask = nil
            self?.isLoadingDeployments = false
        }
    }

    private func cancelPromotionRefresh() {
        promotionTask?.cancel()
        promotionTask = nil
        isLoadingDeployments = false
    }

    /// Awaits the lookup in flight.
    ///
    /// Exists so tests can be deterministic without sleeping. Nothing in the app
    /// calls it — the whole point of the lookup is that nothing waits on it.
    func awaitPromotions() async {
        await promotionTask?.value
    }

    private func refreshPromotions(for merged: [MergedPullRequest]) async {
        guard let deploymentClient else { return }

        let repos = Set(merged.map(\.repo))
        do {
            // Once per repository, ever — including a repository that turned out
            // to deploy nothing, which is stored as an empty array rather than
            // re-searched against a rate-limited endpoint every poll.
            var discovered = false
            for repo in repos where appLocations[repo] == nil {
                appLocations[repo] = try await deploymentClient.discover(repo: repo)
                discovered = true
            }
            if discovered { preferences.setAppLocations(appLocations) }

            let locations = Array(Set(repos.flatMap { appLocations[$0] ?? [] }))
            let byLocation = try await deploymentClient.promotions(for: locations)

            // Re-keyed onto the repository, so a repository backing several apps
            // is answered across all of them at once.
            // Switched off, or the merged list moved on, while this was in the
            // air. Writing the answer now would put chips back on a section the
            // user has already emptied.
            guard !Task.isCancelled else { return }

            promotions = repos.reduce(into: [:]) { result, repo in
                let versions = (appLocations[repo] ?? []).flatMap { byLocation[$0] ?? [] }
                if !versions.isEmpty { result[repo] = versions }
            }
            lastDeploymentFailure = nil
            // Folded into the visible rows now rather than at the next poll,
            // which is what makes the chips arrive on their own.
            rebuildShipments()
        } catch is CancellationError {
            // Nothing to report: the section this belonged to is gone.
        } catch {
            // `promotions` is left alone, for the same reason `shipments` is.
            lastDeploymentFailure = error.localizedDescription
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
    private let themeKey = "appearanceTheme"
    private let monochromeKey = "highContrastMonochrome"
    private let popoverBackgroundKey = "popoverBackground"
    private let staleThresholdKey = "staleThreshold"
    private let mergedWindowKey = "mergedWindow"
    private let appLocationsKey = "appLocations"
    private let launchAtLoginKey = "launchAtLoginRequested"
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

    public func theme() -> AppTheme {
        // Absent *and* unrecognised both fall back to following the system: a
        // downgrade or a stray `defaults write` must not pin somebody to a
        // theme they never chose, and System is the answer that is never wrong.
        defaults.string(forKey: themeKey).flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    public func setTheme(_ value: AppTheme) {
        // The raw string, not an index — `defaults read com.jcll.PRMaster` is
        // how this gets debugged, and "2" says nothing.
        defaults.set(value.rawValue, forKey: themeKey)
    }

    public func monochromeEnabled() -> Bool {
        // `object(forKey:)` for the same reason as `autoUpdateEnabled`: with
        // `bool(forKey:)` a stored false is indistinguishable from an absent
        // key, so switching monochrome off would not survive a relaunch.
        defaults.object(forKey: monochromeKey) as? Bool ?? false
    }

    public func setMonochromeEnabled(_ value: Bool) {
        defaults.set(value, forKey: monochromeKey)
    }

    public func popoverBackground() -> PopoverBackground {
        // Absent and unrecognised both mean liquid glass, which is what the
        // popover did before this setting existed.
        defaults.string(forKey: popoverBackgroundKey)
            .flatMap(PopoverBackground.init(rawValue:)) ?? .liquidGlass
    }

    public func setPopoverBackground(_ value: PopoverBackground) {
        defaults.set(value.rawValue, forKey: popoverBackgroundKey)
    }

    public func staleThreshold() -> StaleThreshold {
        // The one default in here that is not "what the app did before this
        // setting existed" — before it, nothing was marked at all. Marking
        // forgotten pull requests is the whole feature, so an absent key means
        // one month. Unrecognised falls back the same way rather than to `off`:
        // a downgrade or a stray `defaults write` must not silently switch the
        // marker off, which is the one failure nobody would notice.
        defaults.string(forKey: staleThresholdKey)
            .flatMap(StaleThreshold.init(rawValue:)) ?? .oneMonth
    }

    public func setStaleThreshold(_ value: StaleThreshold) {
        defaults.set(value.rawValue, forKey: staleThresholdKey)
    }

    public func mergedWindow() -> MergedWindow {
        // Absent means one day, which is what the section did before this
        // setting existed. Unrecognised falls back the same way rather than to
        // `off`: a downgrade or a stray `defaults write` must not silently empty
        // the section, which is the one failure nobody would notice.
        defaults.string(forKey: mergedWindowKey)
            .flatMap(MergedWindow.init(rawValue:)) ?? .oneDay
    }

    public func setMergedWindow(_ value: MergedWindow) {
        defaults.set(value.rawValue, forKey: mergedWindowKey)
    }

    public func appLocations() -> [String: [AppLocation]] {
        // Unreadable or written by an older shape means "nothing discovered yet",
        // which costs one search per repository to rebuild — the safe direction.
        guard let data = defaults.data(forKey: appLocationsKey),
              let stored = try? JSONDecoder().decode([String: [AppLocation]].self, from: data)
        else { return [:] }
        return stored
    }

    public func setAppLocations(_ value: [String: [AppLocation]]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: appLocationsKey)
    }

    public func launchAtLoginRequested() -> Bool {
        // `object(forKey:)` for the usual reason, with more at stake than
        // anywhere else in here: a stored false that read as an absent key would
        // make the repair on the next launch switch the login item back on for
        // somebody who had just turned it off. Absent means never asked, and
        // never asked has to mean nothing gets registered — an update that put
        // itself in somebody's login items uninvited is what malware does.
        defaults.object(forKey: launchAtLoginKey) as? Bool ?? false
    }

    public func setLaunchAtLoginRequested(_ value: Bool) {
        defaults.set(value, forKey: launchAtLoginKey)
    }
}
