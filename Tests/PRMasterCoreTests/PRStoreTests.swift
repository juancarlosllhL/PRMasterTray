import Foundation
import Testing
@testable import PRMasterCore

private func makePR(
    _ id: String,
    mergeState: MergeStateStatus = .clean,
    headRefOid: String = "oid",
    repo: String = "o/r",
    isPrivate: Bool = false
) -> PullRequest {
    PullRequest(
        id: id, number: 1, title: "test",
        url: URL(string: "https://github.com/o/r/pull/1")!,
        repo: repo, isPrivate: isPrivate, isDraft: false, headRefOid: headRefOid,
        mergeable: .mergeable, mergeState: mergeState,
        reviewDecision: nil, checks: .success, approvals: 0,
        updatedAt: Date(timeIntervalSince1970: 0),
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

/// Serves a scripted sequence of results, one per refresh.
private final class StubClient: PullRequestFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[PullRequest], PRMasterError>]
    private let merged: [MergedPullRequest]
    private(set) var calls = 0

    init(
        _ results: [Result<[PullRequest], PRMasterError>],
        merged: [MergedPullRequest] = []
    ) {
        self.results = results
        self.merged = merged
    }

    func fetchMyPullRequests(mergedWindow: MergedWindow) async throws -> PullRequestSnapshot {
        let next: Result<[PullRequest], PRMasterError> = lock.withLock {
            calls += 1
            return results.isEmpty ? .success([]) : results.removeFirst()
        }
        return PullRequestSnapshot(open: try next.get(), merged: merged)
    }
}

private struct NotifyFailure: Error, LocalizedError {
    var errorDescription: String? { "notification daemon unavailable" }
}

private final class SpyNotifier: ReadyPRNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _notified: [String] = []
    private let failing: Bool

    init(failing: Bool = false) { self.failing = failing }

    var notified: [String] { lock.withLock { _notified } }

    func notifyReady(_ pr: PullRequest) async throws {
        lock.withLock { _notified.append(pr.id) }
        if failing { throw NotifyFailure() }
    }
}

private final class MemoryIDStore: NotifiedIDStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    init(_ initial: Set<String> = []) { ids = initial }
    func load() -> Set<String> { lock.withLock { ids } }
    func save(_ new: Set<String>) { lock.withLock { ids = new } }
}

private struct UpdateFailure: Error, LocalizedError {
    var errorDescription: String? { "merge conflict while updating" }
}

private final class SpyUpdater: PullRequestBranchUpdating, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(id: String, oid: String)] = []
    private let failing: Bool

    init(failing: Bool = false) { self.failing = failing }

    var calls: [(id: String, oid: String)] { lock.withLock { _calls } }

    func updateBranch(id: String, expectedHeadOid: String) async throws {
        lock.withLock { _calls.append((id, expectedHeadOid)) }
        if failing { throw UpdateFailure() }
    }
}

final class MemoryPreferences: PreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var stored: PRFilter
    private var storedTheme: AppTheme
    private var storedMonochrome: Bool
    private var storedBackground: PopoverBackground
    private var storedThreshold: StaleThreshold
    private var storedMergedWindow: MergedWindow
    private var storedLaunchAtLogin: Bool
    private var storedReviewWindow: ReviewWindow
    private var storedTeamFilter: TeamFilter
    private var storedKnownTeams: [Team]

    init(
        autoUpdate: Bool = true,
        filter: PRFilter = PRFilter(),
        theme: AppTheme = .system,
        monochrome: Bool = false,
        background: PopoverBackground = .liquidGlass,
        staleThreshold: StaleThreshold = .oneMonth,
        mergedWindow: MergedWindow = .oneDay,
        launchAtLogin: Bool = false,
        reviewWindow: ReviewWindow = .twoWeeks,
        teamFilter: TeamFilter = TeamFilter(),
        knownTeams: [Team] = []
    ) {
        enabled = autoUpdate
        stored = filter
        storedTheme = theme
        storedMonochrome = monochrome
        storedBackground = background
        storedThreshold = staleThreshold
        storedMergedWindow = mergedWindow
        storedLaunchAtLogin = launchAtLogin
        storedReviewWindow = reviewWindow
        storedTeamFilter = teamFilter
        storedKnownTeams = knownTeams
    }

    func autoUpdateEnabled() -> Bool { lock.withLock { enabled } }
    func setAutoUpdateEnabled(_ value: Bool) { lock.withLock { enabled = value } }
    func filter() -> PRFilter { lock.withLock { stored } }
    func setFilter(_ value: PRFilter) { lock.withLock { stored = value } }
    func theme() -> AppTheme { lock.withLock { storedTheme } }
    func setTheme(_ value: AppTheme) { lock.withLock { storedTheme = value } }
    func monochromeEnabled() -> Bool { lock.withLock { storedMonochrome } }
    func setMonochromeEnabled(_ value: Bool) { lock.withLock { storedMonochrome = value } }
    func popoverBackground() -> PopoverBackground { lock.withLock { storedBackground } }
    func setPopoverBackground(_ value: PopoverBackground) {
        lock.withLock { storedBackground = value }
    }
    func mergedWindow() -> MergedWindow { lock.withLock { storedMergedWindow } }
    func setMergedWindow(_ value: MergedWindow) { lock.withLock { storedMergedWindow = value } }
    func reviewWindow() -> ReviewWindow { lock.withLock { storedReviewWindow } }
    func setReviewWindow(_ value: ReviewWindow) { lock.withLock { storedReviewWindow = value } }
    func teamFilter() -> TeamFilter { lock.withLock { storedTeamFilter } }
    func setTeamFilter(_ value: TeamFilter) { lock.withLock { storedTeamFilter = value } }

    var knownTeamWrites = 0
    func knownTeams() -> [Team] { lock.withLock { storedKnownTeams } }
    func setKnownTeams(_ value: [Team]) {
        lock.withLock {
            storedKnownTeams = value
            knownTeamWrites += 1
        }
    }

    private var storedJiraWindow: JiraWindow = .default
    func jiraWindow() -> JiraWindow { lock.withLock { storedJiraWindow } }
    func setJiraWindow(_ value: JiraWindow) { lock.withLock { storedJiraWindow = value } }

    private var storedJiraLayout: JiraLayout = .default
    func jiraLayout() -> JiraLayout { lock.withLock { storedJiraLayout } }
    func setJiraLayout(_ value: JiraLayout) { lock.withLock { storedJiraLayout = value } }

    private var storedDiffLayout: DiffLayout = .default
    func diffLayout() -> DiffLayout { lock.withLock { storedDiffLayout } }
    func setDiffLayout(_ value: DiffLayout) { lock.withLock { storedDiffLayout = value } }

    private var storedDiffFontFamily: String?
    func diffFontFamily() -> String? { lock.withLock { storedDiffFontFamily } }
    func setDiffFontFamily(_ value: String?) { lock.withLock { storedDiffFontFamily = value } }

    private var storedDiffFontSize = DiffFont.defaultSize
    func diffFontSize() -> Int { lock.withLock { storedDiffFontSize } }
    func setDiffFontSize(_ value: Int) { lock.withLock { storedDiffFontSize = value } }

    private var storedDiffLigatures = true
    func diffLigatures() -> Bool { lock.withLock { storedDiffLigatures } }
    func setDiffLigatures(_ value: Bool) { lock.withLock { storedDiffLigatures = value } }

    private var storedFileScope: [FileSection: [String]] = [:]
    var fileScopeWrites = 0
    func storedFileScopePatterns(_ section: FileSection) -> [String]? { lock.withLock { storedFileScope[section] } }
    func fileScopePatterns(_ section: FileSection) -> [String] {
        lock.withLock { storedFileScope[section] ?? FileScope.defaultPatterns[section] ?? [] }
    }
    func setFileScopePatterns(_ lines: [String]?, for section: FileSection) {
        lock.withLock {
            storedFileScope[section] = lines
            fileScopeWrites += 1
        }
    }

    private var storedHonoursGitAttributes = true
    func honoursGitAttributes() -> Bool { lock.withLock { storedHonoursGitAttributes } }
    func setHonoursGitAttributes(_ value: Bool) { lock.withLock { storedHonoursGitAttributes = value } }
    private var storedHeatmapEnabled = false
    func heatmapEnabled() -> Bool { lock.withLock { storedHeatmapEnabled } }
    func setHeatmapEnabled(_ value: Bool) { lock.withLock { storedHeatmapEnabled = value } }
    private var storedHeatmapBaseURL: String?
    func heatmapBaseURL() -> String? { lock.withLock { storedHeatmapBaseURL } }
    func setHeatmapBaseURL(_ value: String?) { lock.withLock { storedHeatmapBaseURL = value } }

    private var storedAppLocations: [String: [AppLocation]] = [:]
    var appLocationWrites = 0
    func appLocations() -> [String: [AppLocation]] { lock.withLock { storedAppLocations } }
    func setAppLocations(_ value: [String: [AppLocation]]) {
        lock.withLock {
            storedAppLocations = value
            appLocationWrites += 1
        }
    }

    func staleThreshold() -> StaleThreshold { lock.withLock { storedThreshold } }
    func setStaleThreshold(_ value: StaleThreshold) {
        lock.withLock { storedThreshold = value }
    }
    func launchAtLoginRequested() -> Bool { lock.withLock { storedLaunchAtLogin } }
    func setLaunchAtLoginRequested(_ value: Bool) {
        lock.withLock { storedLaunchAtLogin = value }
    }

    private var storedQuips = true
    func approvalQuipsEnabled() -> Bool { lock.withLock { storedQuips } }
    func setApprovalQuipsEnabled(_ value: Bool) { lock.withLock { storedQuips = value } }

    private var storedHidesEmoji = false
    func hidesEmoji() -> Bool { lock.withLock { storedHidesEmoji } }
    func setHidesEmoji(_ value: Bool) { lock.withLock { storedHidesEmoji = value } }

    private var storedLastSeenVersion: String?
    private var written = false
    func lastSeenVersion() -> String? { lock.withLock { storedLastSeenVersion } }
    func setLastSeenVersion(_ value: String) {
        lock.withLock { storedLastSeenVersion = value; written = true }
    }
    func hasStoredSettings() -> Bool { lock.withLock { written } }
    /// Stands in for an install that has been used before, whatever it wrote.
    func markUsed() { lock.withLock { written = true } }
}

@MainActor
@Suite("PRStore")
struct PRStoreTests {

    private func makeStore(
        _ results: [Result<[PullRequest], PRMasterError>],
        notified: Set<String> = [],
        notifierFails: Bool = false,
        preferences: MemoryPreferences = MemoryPreferences(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> (PRStore, StubClient, SpyNotifier, MemoryIDStore) {
        let client = StubClient(results)
        let notifier = SpyNotifier(failing: notifierFails)
        let idStore = MemoryIDStore(notified)
        let store = PRStore(
            client: client,
            notifier: notifier,
            idStore: idStore,
            preferences: preferences,
            now: { Date(timeIntervalSince1970: 1000) },
            sleep: sleep
        )
        return (store, client, notifier, idStore)
    }

    // MARK: state

    @Test("a successful refresh populates state and clears the error")
    func successPopulates() async {
        let (store, _, _, _) = makeStore([.success([makePR("a")])])
        await store.refresh()
        #expect(store.prs.map(\.id) == ["a"])
        #expect(store.lastError == nil)
        #expect(store.lastSuccessfulFetch == Date(timeIntervalSince1970: 1000))
    }

    /// A wifi blip must not make the app look like you have no open PRs.
    @Test("a failed refresh keeps the last good data")
    func staleBeatsBlank() async {
        let (store, _, _, _) = makeStore([
            .success([makePR("a"), makePR("b")]),
            .failure(.network(URLError(.notConnectedToInternet))),
        ])
        await store.refresh()
        let stamp = store.lastSuccessfulFetch

        await store.refresh()
        #expect(store.prs.count == 2, "the list must survive a failed refresh")
        #expect(store.lastError != nil)
        #expect(store.lastSuccessfulFetch == stamp, "the stamp must not advance on failure")
    }

    @Test("recovering clears the error")
    func recoveryClearsError() async {
        let (store, _, _, _) = makeStore([
            .failure(.unauthorized),
            .success([makePR("a")]),
        ])
        await store.refresh()
        #expect(store.lastError != nil)
        await store.refresh()
        #expect(store.lastError == nil)
    }

    // MARK: backoff

    @Test("backoff climbs 60, 120, 300 and caps there")
    func backoffClimbs() async {
        let (store, _, _, _) = makeStore(Array(repeating: .failure(.unauthorized), count: 4))
        #expect(store.currentInterval == .seconds(60))
        await store.refresh()
        #expect(store.currentInterval == .seconds(120))
        await store.refresh()
        #expect(store.currentInterval == .seconds(300))
        await store.refresh()
        #expect(store.currentInterval == .seconds(300), "must cap, not grow forever")
    }

    @Test("a success resets the backoff")
    func backoffResets() async {
        let (store, _, _, _) = makeStore([
            .failure(.unauthorized),
            .failure(.unauthorized),
            .success([]),
        ])
        await store.refresh()
        await store.refresh()
        #expect(store.currentInterval == .seconds(300))
        await store.refresh()
        #expect(store.currentInterval == .seconds(60))
    }

    // MARK: notifications

    @Test("a newly ready PR notifies once and is persisted")
    func notifiesOnce() async {
        let (store, _, notifier, idStore) = makeStore([
            .success([makePR("a")]),
            .success([makePR("a")]),
        ])
        await store.refresh()
        await store.refresh()
        #expect(notifier.notified == ["a"], "must not notify twice for the same transition")
        #expect(idStore.load() == ["a"], "state must survive a relaunch")
    }

    /// Otherwise a network flap would look like every PR going ready at once.
    @Test("a failed refresh never notifies")
    func failureNeverNotifies() async {
        let (store, _, notifier, _) = makeStore([
            .failure(.network(URLError(.timedOut))),
        ])
        await store.refresh()
        #expect(notifier.notified.isEmpty)
    }

    @Test("a blocked PR does not notify")
    func blockedDoesNotNotify() async {
        let (store, _, notifier, _) = makeStore([.success([makePR("a", mergeState: .blocked)])])
        await store.refresh()
        #expect(notifier.notified.isEmpty)
    }

    @Test("previously notified IDs are loaded at startup")
    func loadsPersistedIDs() async {
        let (store, _, notifier, _) = makeStore([.success([makePR("a")])], notified: ["a"])
        await store.refresh()
        #expect(notifier.notified.isEmpty, "a relaunch must not re-notify")
    }

    // MARK: poll loop

    @Test("the poll loop refreshes repeatedly and honours cancellation")
    func pollLoopRuns() async {
        let counter = Counter()
        let (store, client, _, _) = makeStore(
            Array(repeating: .success([]), count: 5),
            sleep: { duration in
                counter.record(duration)
                // Stand in for cancellation after a few cycles.
                if counter.count >= 3 { throw CancellationError() }
            }
        )
        await store.pollLoop()
        #expect(client.calls == 3, "should refresh once per cycle until cancelled")
        #expect(counter.durations.allSatisfy { $0 == .seconds(60) })
    }

    @Test("the poll loop waits longer after failures")
    func pollLoopBacksOff() async {
        let counter = Counter()
        let (store, _, _, _) = makeStore(
            Array(repeating: .failure(.unauthorized), count: 5),
            sleep: { duration in
                counter.record(duration)
                if counter.count >= 3 { throw CancellationError() }
            }
        )
        await store.pollLoop()
        #expect(counter.durations == [.seconds(120), .seconds(300), .seconds(300)])
    }

    // MARK: undelivered notifications

    /// Previously the ID was recorded before delivery was attempted, so a
    /// swallowed failure meant the PR was never notified about again unless it
    /// left the ready state and came back.
    @Test("a failed notification is not recorded, so it retries next poll")
    func failedNotificationRetries() async {
        let (store, _, notifier, idStore) = makeStore(
            [.success([makePR("a")]), .success([makePR("a")])],
            notifierFails: true
        )
        await store.refresh()
        #expect(idStore.load().isEmpty, "an undelivered PR must not be recorded")

        await store.refresh()
        #expect(notifier.notified == ["a", "a"], "should try again on the next poll")
    }

    @Test("a delivery failure is surfaced, not swallowed")
    func failureIsVisible() async {
        let (store, _, _, _) = makeStore([.success([makePR("a")])], notifierFails: true)
        await store.refresh()
        #expect(store.lastNotificationFailure == "notification daemon unavailable")
    }

    @Test("a later success clears the delivery failure")
    func failureClears() async {
        let (store, _, _, _) = makeStore([.success([makePR("a")])])
        await store.refresh()
        #expect(store.lastNotificationFailure == nil)
    }

    /// Only the freshly-failed PR drops out; already-notified ones must stay
    /// recorded or they would notify twice.
    @Test("a failure does not un-record previously notified PRs")
    func failureKeepsEarlierIDs() async {
        let (store, _, _, idStore) = makeStore(
            [.success([makePR("a"), makePR("b")])],
            notified: ["a"],
            notifierFails: true
        )
        await store.refresh()
        #expect(idStore.load() == ["a"], "a stays recorded, b retries")
    }

    // MARK: reentrancy

    /// Poll loop, popover open, wake, post-merge and the manual button can all
    /// call refresh; overlapping fetches let the slower one restore stale data.
    @Test("an overlapping refresh is rejected while one is in flight")
    func refreshIsNotReentrant() async {
        let (store, client, _, _) = makeStore([.success([makePR("a")]), .success([])])
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)
        #expect(client.calls == 1, "the second call must be dropped, not queued")
    }

    @Test("refresh works again once the previous one finished")
    func refreshResumesAfterCompletion() async {
        let (store, client, _, _) = makeStore([.success([]), .success([])])
        await store.refresh()
        await store.refresh()
        #expect(client.calls == 2)
    }

    @Test("readyCount reflects only mergeable PRs")
    func readyCount() async {
        let (store, _, _, _) = makeStore([.success([
            makePR("a"), makePR("b", mergeState: .blocked), makePR("c"),
        ])])
        await store.refresh()
        #expect(store.readyCount == 2)
    }

    // MARK: automatic branch update

    private func makeUpdatingStore(
        _ results: [Result<[PullRequest], PRMasterError>],
        updater: SpyUpdater? = SpyUpdater(),
        preferences: MemoryPreferences = MemoryPreferences()
    ) -> (PRStore, SpyUpdater?) {
        let store = PRStore(
            client: StubClient(results),
            notifier: SpyNotifier(),
            idStore: MemoryIDStore(),
            updater: updater,
            preferences: preferences,
            now: { Date(timeIntervalSince1970: 1000) },
            sleep: { _ in }
        )
        return (store, updater)
    }

    @Test("a behind PR is updated once, with the snapshot's head oid")
    func updatesBehindPR() async {
        let (store, updater) = makeUpdatingStore([
            .success([makePR("a", mergeState: .behind, headRefOid: "sha_a")]),
        ])
        await store.refresh()
        #expect(updater?.calls.map(\.id) == ["a"])
        #expect(updater?.calls.map(\.oid) == ["sha_a"])
    }

    @Test("a PR that is not behind is left alone")
    func leavesOtherStatesAlone() async {
        let (store, updater) = makeUpdatingStore([
            .success([makePR("a"), makePR("b", mergeState: .blocked)]),
        ])
        await store.refresh()
        #expect(updater?.calls.isEmpty == true)
    }

    /// A refused update leaves the head oid untouched, so an unguarded retry
    /// would fire the same doomed mutation every 60 seconds forever.
    @Test("the same behind PR is not updated again on the next poll")
    func doesNotRetrySameHead() async {
        let pr = makePR("a", mergeState: .behind, headRefOid: "sha_a")
        let (store, updater) = makeUpdatingStore([.success([pr]), .success([pr])])
        await store.refresh()
        await store.refresh()
        #expect(updater?.calls.count == 1)
    }

    @Test("a new head oid re-arms the update")
    func newHeadRetries() async {
        let (store, updater) = makeUpdatingStore([
            .success([makePR("a", mergeState: .behind, headRefOid: "sha_a")]),
            .success([makePR("a", mergeState: .behind, headRefOid: "sha_b")]),
        ])
        await store.refresh()
        await store.refresh()
        #expect(updater?.calls.map(\.oid) == ["sha_a", "sha_b"])
    }

    /// The seam the debug-override gate plugs into. Fixture rows carry real
    /// node IDs, and unlike merging there is no click standing in the way.
    @Test("a nil updater disables the feature outright")
    func nilUpdaterIsANoOp() async {
        let (store, _) = makeUpdatingStore(
            [.success([makePR("a", mergeState: .behind)])],
            updater: nil
        )
        await store.refresh()
        #expect(store.prs.count == 1, "the refresh itself must still work")
        #expect(store.lastUpdateFailure == nil)
    }

    @Test("the preference switches the feature off")
    func preferenceDisables() async {
        let (store, updater) = makeUpdatingStore(
            [.success([makePR("a", mergeState: .behind)])],
            preferences: MemoryPreferences(autoUpdate: false)
        )
        #expect(store.autoUpdateEnabled == false, "must adopt the stored preference")
        await store.refresh()
        #expect(updater?.calls.isEmpty == true)
    }

    @Test("toggling the preference writes through so it survives a relaunch")
    func preferencePersists() {
        let preferences = MemoryPreferences(autoUpdate: true)
        let (store, _) = makeUpdatingStore([], preferences: preferences)
        store.autoUpdateEnabled = false
        #expect(preferences.autoUpdateEnabled() == false)
    }

    /// Otherwise a network flap would look like every PR falling behind at once.
    @Test("a failed refresh never updates anything")
    func failureNeverUpdates() async {
        let (store, updater) = makeUpdatingStore([.failure(.network(URLError(.timedOut)))])
        await store.refresh()
        #expect(updater?.calls.isEmpty == true)
    }

    @Test("a failed update is surfaced and does not abort the refresh")
    func updateFailureIsVisible() async {
        let (store, _) = makeUpdatingStore(
            [.success([makePR("a", mergeState: .behind)])],
            updater: SpyUpdater(failing: true)
        )
        await store.refresh()
        #expect(store.lastUpdateFailure == "merge conflict while updating")
        #expect(store.prs.count == 1, "the list must still be published")
        #expect(store.lastError == nil, "an update failure is not a fetch failure")
    }

    @Test("a clean poll clears a previous update failure")
    func updateFailureClears() async {
        let (store, _) = makeUpdatingStore([
            .success([makePR("a", mergeState: .behind)]),
            .success([makePR("a")]),
        ], updater: SpyUpdater(failing: true))
        await store.refresh()
        #expect(store.lastUpdateFailure != nil)
        await store.refresh()
        #expect(store.lastUpdateFailure == nil)
    }

    /// Otherwise the warning outlives the feature that produced it, and the
    /// user is told about a failure the app is no longer even trying.
    @Test("switching auto-update off clears a stale failure")
    func disablingClearsFailure() async {
        let preferences = MemoryPreferences(autoUpdate: true)
        let (store, _) = makeUpdatingStore([
            .success([makePR("a", mergeState: .behind)]),
            .success([makePR("a", mergeState: .behind)]),
        ], updater: SpyUpdater(failing: true), preferences: preferences)

        await store.refresh()
        #expect(store.lastUpdateFailure != nil)

        store.autoUpdateEnabled = false
        await store.refresh()
        #expect(store.lastUpdateFailure == nil)
    }

    // MARK: staleness threshold

    /// The one setting in this app whose default deliberately changes what an
    /// existing install shows. That is the point of the feature, so the default
    /// has to be the documented one rather than "whatever the app did before".
    @Test("an absent threshold adopts one month")
    func adoptsDefaultThreshold() {
        let (store, _, _, _) = makeStore([])
        #expect(store.staleThreshold == .oneMonth)
    }

    @Test("the stored threshold is adopted at launch", arguments: StaleThreshold.allCases)
    func adoptsStoredThreshold(threshold: StaleThreshold) {
        let (store, _, _, _) = makeStore([], preferences: MemoryPreferences(staleThreshold: threshold))
        #expect(store.staleThreshold == threshold)
    }

    @Test("moving the threshold writes through so it survives a relaunch")
    func thresholdPersists() {
        let preferences = MemoryPreferences()
        let (store, _, _, _) = makeStore([], preferences: preferences)
        store.staleThreshold = .sixMonths
        #expect(preferences.staleThreshold() == .sixMonths)
    }

    /// Switching the marker off has to persist too. The failure mode this guards
    /// is the same one `monochromeEnabled` had: a setting that silently reverts.
    @Test("switching the marker off persists as well")
    func offPersists() {
        let preferences = MemoryPreferences(staleThreshold: .oneMonth)
        let (store, _, _, _) = makeStore([], preferences: preferences)
        store.staleThreshold = .off
        #expect(preferences.staleThreshold() == .off)
    }

    // MARK: filtering

    private func makeFilteringStore(
        _ prs: [PullRequest],
        filter: PRFilter,
        refreshes: Int = 1
    ) -> (PRStore, SpyNotifier, SpyUpdater, MemoryPreferences) {
        let notifier = SpyNotifier()
        let updater = SpyUpdater()
        let preferences = MemoryPreferences(filter: filter)
        let store = PRStore(
            client: StubClient(Array(repeating: .success(prs), count: refreshes)),
            notifier: notifier,
            idStore: MemoryIDStore(),
            updater: updater,
            preferences: preferences,
            now: { Date(timeIntervalSince1970: 1000) },
            sleep: { _ in }
        )
        return (store, notifier, updater, preferences)
    }

    @Test("the stored filter is adopted at launch")
    func adoptsStoredFilter() {
        let (store, _, _, _) = makeFilteringStore([], filter: PRFilter(hiddenOrganizations: ["acme"]))
        #expect(store.filter.hiddenOrganizations == ["acme"])
    }

    @Test("a hidden organization is left out of the list")
    func hiddenOrganizationIsNotListed() async {
        let (store, _, _, _) = makeFilteringStore([
            makePR("a", repo: "acme/widget"),
            makePR("b", repo: "widgetco/api"),
        ], filter: PRFilter(hiddenOrganizations: ["acme"]))
        await store.refresh()
        #expect(store.prs.map(\.id) == ["b"])
        #expect(store.allPRs.count == 2, "the unfiltered snapshot must be kept")
        #expect(store.hiddenCount == 1)
    }

    @Test("private pull requests are left out when the switch is off")
    func privateIsNotListed() async {
        let (store, _, _, _) = makeFilteringStore([
            makePR("a", repo: "acme/widget", isPrivate: true),
            makePR("b", repo: "acme/api"),
        ], filter: PRFilter(showsPrivateRepositories: false))
        await store.refresh()
        #expect(store.prs.map(\.id) == ["b"])
    }

    /// The point of hiding something is not hearing about it. A filter that only
    /// shortened the list would still wake the user up at 2am for a PR they
    /// deliberately switched off.
    @Test("a hidden pull request never notifies")
    func hiddenNeverNotifies() async {
        let (store, notifier, _, _) = makeFilteringStore(
            [makePR("a", repo: "acme/widget")],
            filter: PRFilter(hiddenOrganizations: ["acme"])
        )
        await store.refresh()
        #expect(notifier.notified.isEmpty)
    }

    /// Sharper than the notification case: this one writes to GitHub off a timer.
    @Test("a hidden pull request is never brought up to date")
    func hiddenIsNeverUpdated() async {
        let (store, _, updater, _) = makeFilteringStore(
            [makePR("a", mergeState: .behind, repo: "acme/widget")],
            filter: PRFilter(hiddenOrganizations: ["acme"])
        )
        await store.refresh()
        #expect(updater.calls.isEmpty)
    }

    @Test("the menu bar count ignores hidden pull requests")
    func hiddenIsNotCounted() async {
        let (store, _, _, _) = makeFilteringStore([
            makePR("a", repo: "acme/widget"),
            makePR("b", repo: "widgetco/api"),
        ], filter: PRFilter(hiddenOrganizations: ["acme"]))
        await store.refresh()
        #expect(store.readyCount == 1)
    }

    /// An empty list is a legitimate outcome of a *successful* fetch, so none of
    /// the failure state may be set — otherwise the popover shows an error.
    @Test("a filter that hides everything is not a failure")
    func hidingEverythingIsNotAnError() async {
        let (store, _, _, _) = makeFilteringStore(
            [makePR("a", repo: "acme/widget")],
            filter: PRFilter(hiddenOrganizations: ["acme"])
        )
        await store.refresh()
        #expect(store.prs.isEmpty)
        #expect(store.lastError == nil)
        #expect(store.lastSuccessfulFetch == Date(timeIntervalSince1970: 1000))
    }

    /// The settings window is opened from the popover, so waiting a poll interval
    /// to see the effect would read as the switch not working.
    @Test("changing the filter re-filters the snapshot without fetching again")
    func filterChangeRefiltersImmediately() async {
        let (store, _, _, _) = makeFilteringStore([
            makePR("a", repo: "acme/widget"),
            makePR("b", repo: "widgetco/api"),
        ], filter: PRFilter())
        await store.refresh()
        #expect(store.prs.count == 2)

        store.filter.setOrganization("acme", shown: false)
        #expect(store.prs.map(\.id) == ["b"], "must re-filter from the snapshot in hand")
        #expect(store.hiddenCount == 1)

        store.filter.setOrganization("acme", shown: true)
        #expect(store.prs.count == 2, "unhiding must bring it back without a fetch")
    }

    @Test("changing the filter writes through so it survives a relaunch")
    func filterPersists() {
        let (store, _, _, preferences) = makeFilteringStore([], filter: PRFilter())
        store.filter.showsPrivateRepositories = false
        #expect(preferences.filter().showsPrivateRepositories == false)
    }

    /// Otherwise switching an organization off would remove it from the very
    /// window you switch it back on in.
    @Test("knownOrganizations includes hidden ones and is sorted")
    func knownOrganizationsIncludesHidden() async {
        let (store, _, _, _) = makeFilteringStore([
            makePR("a", repo: "widgetco/api"),
            makePR("b", repo: "acme/widget"),
        ], filter: PRFilter(hiddenOrganizations: ["zeta", "acme"]))
        await store.refresh()
        #expect(store.knownOrganizations == ["acme", "widgetco", "zeta"])
    }

    /// The app writes to GitHub with no user gesture, so it has to say so while
    /// it happens — and stop saying so once it is done.
    @Test("updatingIDs is empty once the refresh returns")
    func updatingIDsAreCleared() async {
        let (store, _) = makeUpdatingStore([
            .success([makePR("a", mergeState: .behind)]),
        ], updater: SpyUpdater(failing: true))
        #expect(store.updatingIDs.isEmpty)
        await store.refresh()
        #expect(store.updatingIDs.isEmpty, "must clear even when the update failed")
    }
}

@Suite("Stored preferences")
struct PreferenceStoreTests {

    /// `UserDefaults.bool(forKey:)` returns false for an absent key, which would
    /// ship the feature silently switched off for every existing install.
    @Test("an absent preference reads as enabled")
    func defaultsToOn() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserDefaultsPreferences(defaults: defaults).autoUpdateEnabled() == true)
    }

    @Test("a stored preference round-trips", arguments: [true, false])
    func roundTrips(value: Bool) throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setAutoUpdateEnabled(value)
        #expect(preferences.autoUpdateEnabled() == value)
    }

    /// Same reasoning as the auto-update default, with more at stake: a filter
    /// that read as "hide private" for an absent key would empty the list of
    /// every existing install on the first launch after updating.
    @Test("an absent filter hides nothing")
    func filterDefaultsToShowingEverything() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let filter = UserDefaultsPreferences(defaults: defaults).filter()
        #expect(filter == PRFilter())
        #expect(filter.isActive == false)
    }

    @Test("a stored filter round-trips")
    func filterRoundTrips() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setFilter(
            PRFilter(hiddenOrganizations: ["acme", "widgetco"], showsPrivateRepositories: false)
        )
        let restored = preferences.filter()
        #expect(restored.hiddenOrganizations == ["acme", "widgetco"])
        #expect(restored.showsPrivateRepositories == false)
    }

    /// Unhiding the last organization has to clear the stored list, not leave the
    /// previous one behind.
    @Test("an emptied filter round-trips as empty")
    func filterClears() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setFilter(PRFilter(hiddenOrganizations: ["acme"]))
        preferences.setFilter(PRFilter())
        #expect(preferences.filter() == PRFilter())
    }

    // MARK: - Staleness

    /// The deliberate exception to the rule the rest of this suite enforces. Every
    /// other absent key means "what the app did before this setting existed";
    /// here it means one month, because marking forgotten pull requests is the
    /// whole point and a feature that shipped switched off would be nothing.
    @Test("an absent threshold reads as one month")
    func thresholdDefaultsToOneMonth() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserDefaultsPreferences(defaults: defaults).staleThreshold() == .oneMonth)
    }

    @Test("a stored threshold round-trips", arguments: StaleThreshold.allCases)
    func thresholdRoundTrips(threshold: StaleThreshold) throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setStaleThreshold(threshold)
        #expect(preferences.staleThreshold() == threshold)
    }

    /// A downgrade or a stray `defaults write` must not switch the marker off, so
    /// an unrecognised value falls back to the default rather than to `off`.
    @Test("an unrecognised stored threshold falls back to one month")
    func unknownThresholdFallsBack() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("fortnight", forKey: "staleThreshold")
        #expect(UserDefaultsPreferences(defaults: defaults).staleThreshold() == .oneMonth)
    }

    /// Same reason as the theme: `defaults read com.jcll.PRMaster` is how this
    /// gets debugged, and an index says nothing.
    @Test("the threshold is stored as a readable string")
    func thresholdIsStoredReadably() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        UserDefaultsPreferences(defaults: defaults).setStaleThreshold(.threeMonths)
        #expect(defaults.string(forKey: "staleThreshold") == "threeMonths")
    }

    /// Building a store must not write the default back. If it did, the key would
    /// be pinned at whatever this version's default happened to be, and a later
    /// change to that default would never reach anybody who had already launched.
    @Test("constructing a store does not persist the default threshold")
    @MainActor
    func storeInitDoesNotPinTheThreshold() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PRStore(
            client: StubClient([]),
            notifier: SpyNotifier(),
            idStore: MemoryIDStore(),
            preferences: UserDefaultsPreferences(defaults: defaults)
        )

        #expect(store.staleThreshold == .oneMonth)
        #expect(defaults.object(forKey: "staleThreshold") == nil, "the key must stay absent")
    }

    // MARK: - Launch at login

    /// The one default in here with more at stake than a repainted popover: an
    /// absent key that read as "asked for" would put the app in the login items
    /// of every existing install without anybody choosing it, which is what
    /// malware does.
    @Test("an absent launch-at-login intent reads as never asked")
    func launchAtLoginDefaultsToOff() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserDefaultsPreferences(defaults: defaults).launchAtLoginRequested() == false)
    }

    /// The stored `false` matters as much as the stored `true`: with
    /// `bool(forKey:)` it would be indistinguishable from an absent key, and the
    /// repair on the next launch would switch the login item back on for somebody
    /// who had just turned it off.
    @Test("a stored launch-at-login intent round-trips", arguments: [true, false])
    func launchAtLoginRoundTrips(value: Bool) throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setLaunchAtLoginRequested(value)
        #expect(preferences.launchAtLoginRequested() == value)
    }

    // MARK: - Appearance

    /// The same rule as every other default in here: an absent key has to mean
    /// "what the app did before this setting existed". Anything else repaints
    /// every existing install on the first launch after updating.
    @Test("an absent theme follows the system")
    func themeDefaultsToSystem() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserDefaultsPreferences(defaults: defaults).theme() == .system)
    }

    @Test("a stored theme round-trips", arguments: AppTheme.allCases)
    func themeRoundTrips(theme: AppTheme) throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setTheme(theme)
        #expect(preferences.theme() == theme)
    }

    /// A downgrade, a typo in `defaults write`, or a theme that existed in a
    /// later version — none of which should pin somebody to a theme they never
    /// chose. Following the system is the one answer that is never wrong.
    @Test("an unrecognised stored theme falls back to the system")
    func unknownThemeFallsBack() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("solarized", forKey: "appearanceTheme")
        #expect(UserDefaultsPreferences(defaults: defaults).theme() == .system)
    }

    /// Stored as the raw string rather than an index, because `defaults read
    /// com.jcll.PRMaster` is how this gets debugged and "2" says nothing.
    @Test("the theme is stored as a readable string")
    func themeIsStoredReadably() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        UserDefaultsPreferences(defaults: defaults).setTheme(.dark)
        #expect(defaults.string(forKey: "appearanceTheme") == "dark")
    }

    /// Liquid glass is what the popover did before any of this work, so an absent
    /// key has to mean that. Opaque is the option somebody opts into, knowing it
    /// trades the native look for a contrast guarantee.
    @Test("an absent popover background reads as liquid glass")
    func backgroundDefaultsToLiquidGlass() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserDefaultsPreferences(defaults: defaults).popoverBackground() == .liquidGlass)
    }

    @Test("a stored popover background round-trips", arguments: PopoverBackground.allCases)
    func backgroundRoundTrips(style: PopoverBackground) throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setPopoverBackground(style)
        #expect(preferences.popoverBackground() == style)
    }

    @Test("an unrecognised stored background falls back to liquid glass")
    func unknownBackgroundFallsBack() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("frosted", forKey: "popoverBackground")
        #expect(UserDefaultsPreferences(defaults: defaults).popoverBackground() == .liquidGlass)
    }

    /// Off unless asked for: monochrome is a deliberate choice, and the app has
    /// never drawn that way before.
    @Test("an absent monochrome flag reads as off")
    func monochromeDefaultsToOff() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserDefaultsPreferences(defaults: defaults).monochromeEnabled() == false)
    }

    @Test("a stored monochrome flag round-trips", arguments: [true, false])
    func monochromeRoundTrips(value: Bool) throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setMonochromeEnabled(value)
        #expect(preferences.monochromeEnabled() == value)
    }

    /// `bool(forKey:)` cannot tell an absent key from a stored false, so a
    /// stored false has to survive a round trip distinctly from never having
    /// been set — otherwise switching monochrome off would not persist.
    @Test("a stored false is not mistaken for an absent key")
    func storedFalseSurvives() throws {
        let suite = "PRMasterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setMonochromeEnabled(true)
        preferences.setMonochromeEnabled(false)
        #expect(preferences.monochromeEnabled() == false)
        #expect(defaults.object(forKey: "highContrastMonochrome") as? Bool == false)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    var durations: [Duration] { lock.withLock { _durations } }
    var count: Int { lock.withLock { _durations.count } }
    func record(_ d: Duration) { lock.withLock { _durations.append(d) } }
}

private final class SpyMerger: PullRequestMerging, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _seen: (progress: MergeProgress?, readyCount: Int)?
    private let error: PRMasterError?
    weak var store: PRStore?
    /// Runs while GitHub is "merging", e.g. a poll landing mid-flight.
    var during: (@Sendable () async -> Void)?

    init(error: PRMasterError? = nil) { self.error = error }

    var calls: [String] { lock.withLock { _calls } }
    /// What the row and the badge said while GitHub was merging.
    var seenWhileMerging: (progress: MergeProgress?, readyCount: Int)? { lock.withLock { _seen } }

    func squashMerge(id: String, expectedHeadOid: String) async throws {
        await during?()
        let seen = await MainActor.run { (self.store?.merges[id], self.store?.readyCount ?? -1) }
        lock.withLock {
            _calls.append(id)
            _seen = seen
        }
        if let error { throw error }
    }
}

@MainActor
private final class ConfirmSpy {
    private(set) var asks = 0
    func answer(_ value: Bool) -> Bool {
        asks += 1
        return value
    }
}

@MainActor
@Suite("PRStore merging")
struct PRStoreMergeTests {

    private func makeStore(
        _ results: [Result<[PullRequest], PRMasterError>],
        merger: SpyMerger? = SpyMerger(),
        notifier: SpyNotifier = SpyNotifier(),
        updater: SpyUpdater? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> (PRStore, StubClient) {
        let client = StubClient(results)
        let store = PRStore(
            client: client,
            notifier: notifier,
            idStore: MemoryIDStore(),
            updater: updater,
            merger: merger.map { MergeCoordinator(client: $0, mergingAllowed: true) },
            preferences: MemoryPreferences(),
            now: { Date(timeIntervalSince1970: 1000) },
            sleep: sleep
        )
        merger?.store = store
        return (store, client)
    }

    private func listed(_ pr: PullRequest, times: Int = 6) -> [Result<[PullRequest], PRMasterError>] {
        Array(repeating: .success([pr]), count: times)
    }

    @Test("a confirmed merge reads merging while GitHub merges, merged after, and leaves the badge")
    func confirmedMerge() async {
        let merger = SpyMerger()
        let (store, _) = makeStore(listed(makePR("a")), merger: merger)
        await store.refresh()
        #expect(store.readyCount == 1)

        let outcome = await store.merge(id: "a", expectedHeadOid: "oid") { true }

        #expect(outcome == .merged)
        #expect(merger.seenWhileMerging?.progress == .merging)
        #expect(merger.seenWhileMerging?.readyCount == 0)
        #expect(store.merges["a"] == .merged)
        #expect(store.readyCount == 0)
    }

    @Test("declining at the confirmation marks nothing and reaches no network")
    func declinedMerge() async {
        let merger = SpyMerger()
        let (store, _) = makeStore(listed(makePR("a")), merger: merger)
        await store.refresh()

        let outcome = await store.merge(id: "a", expectedHeadOid: "oid") { false }

        #expect(outcome == .cancelled)
        #expect(merger.calls.isEmpty)
        #expect(store.merges.isEmpty)
        #expect(store.readyCount == 1)
    }

    @Test("a refused merge puts the row back to ready, with GitHub's message")
    func failedMerge() async {
        let merger = SpyMerger(error: .mergeRejected("Head branch was modified."))
        let (store, _) = makeStore(listed(makePR("a")), merger: merger)
        await store.refresh()

        let outcome = await store.merge(id: "a", expectedHeadOid: "oid") { true }

        #expect(outcome == .failed("Head branch was modified."))
        #expect(merger.seenWhileMerging?.progress == .merging)
        #expect(store.merges.isEmpty)
        #expect(store.readyCount == 1)
    }

    /// The notification's Merge can arrive for a row the popover already merged.
    @Test("merging a row already merged asks nothing and leaves it merged")
    func secondMergeAfterwards() async {
        let merger = SpyMerger()
        let (store, _) = makeStore(listed(makePR("a")), merger: merger)
        await store.refresh()
        _ = await store.merge(id: "a", expectedHeadOid: "oid") { true }
        let confirm = ConfirmSpy()

        let outcome = await store.merge(id: "a", expectedHeadOid: "oid") { confirm.answer(true) }

        #expect(outcome == .cancelled)
        #expect(confirm.asks == 0)
        #expect(merger.calls == ["a"])
        #expect(store.merges["a"] == .merged)
    }

    @Test("a merge that lands while another dialog is up wins, and the dialog's answer is dropped")
    func secondMergeDuringDialog() async {
        let merger = SpyMerger()
        let (store, _) = makeStore(listed(makePR("a")), merger: merger)
        await store.refresh()

        let outcome = await store.merge(id: "a", expectedHeadOid: "oid") {
            _ = await store.merge(id: "a", expectedHeadOid: "oid") { true }
            return true
        }

        #expect(outcome == .cancelled)
        #expect(merger.calls == ["a"])
        #expect(store.merges["a"] == .merged)
    }

    @Test("a store with no merger refuses and marks nothing")
    func noMerger() async {
        let (store, _) = makeStore(listed(makePR("a")), merger: nil)
        await store.refresh()

        let outcome = await store.merge(id: "a", expectedHeadOid: "oid") { true }

        #expect(outcome == .refusedDebugOverride)
        #expect(store.merges.isEmpty)
    }

    // MARK: reconciling with the search

    /// Holds the follow-up re-checks back, so each refresh here is the test's own.
    private static let parked: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3600))
    }

    @Test("a merged row stays while the search still lists it, and goes once it does not")
    func mergedRowWaitsForTheSearch() async {
        let (store, client) = makeStore(
            [.success([makePR("a")]), .success([makePR("a")]), .success([makePR("a")]), .success([])],
            sleep: Self.parked
        )
        defer { store.stop() }
        await store.refresh()

        _ = await store.merge(id: "a", expectedHeadOid: "oid") { true }
        #expect(client.calls == 2)
        #expect(store.merges["a"] == .merged)

        await store.refresh()
        #expect(store.merges["a"] == .merged)
        #expect(store.prs.map(\.id) == ["a"])

        await store.refresh()
        #expect(store.merges.isEmpty)
        #expect(store.prs.isEmpty)
    }

    @Test("a poll landing mid-merge does not drop the row's merging state")
    func mergingSurvivesARefresh() async {
        let merger = SpyMerger()
        let (store, _) = makeStore([.success([makePR("a")]), .success([])], merger: merger, sleep: Self.parked)
        defer { store.stop() }
        merger.during = { await store.refresh() }
        await store.refresh()

        _ = await store.merge(id: "a", expectedHeadOid: "oid") { true }

        #expect(merger.seenWhileMerging?.progress == .merging)
        #expect(store.merges.isEmpty)
    }

    /// The stale search returns the merged pull request with live fields, which can
    /// read as not ready and then ready again, re-arming the notification.
    @Test("a merged row the search still lists is never notified about again")
    func mergedRowIsNotNotified() async {
        let notifier = SpyNotifier()
        let (store, _) = makeStore(
            [
                .success([makePR("a")]), .success([makePR("a")]),
                .success([makePR("a", mergeState: .unknown)]), .success([makePR("a")]),
            ],
            notifier: notifier,
            sleep: Self.parked
        )
        defer { store.stop() }
        await store.refresh()
        #expect(notifier.notified == ["a"])

        _ = await store.merge(id: "a", expectedHeadOid: "oid") { true }
        await store.refresh()
        await store.refresh()

        #expect(notifier.notified == ["a"])
    }

    @Test("a merged row the search still lists as behind is not brought up to date")
    func mergedRowIsNotUpdated() async {
        let updater = SpyUpdater()
        let (store, _) = makeStore(
            [.success([makePR("a")]), .success([makePR("a")]), .success([makePR("a", mergeState: .behind)])],
            updater: updater,
            sleep: Self.parked
        )
        defer { store.stop() }
        await store.refresh()

        _ = await store.merge(id: "a", expectedHeadOid: "oid") { true }
        await store.refresh()

        #expect(updater.calls.isEmpty)
    }

    // MARK: re-checks after a merge

    @Test("after a merge the list is re-checked at 5 and 10 s, and no more once the row has moved")
    func rechecksStopOnceTheRowMoves() async {
        let sleeps = Counter()
        let (store, client) = makeStore(
            [.success([makePR("a")]), .success([makePR("a")]), .success([makePR("a")]), .success([])],
            sleep: { sleeps.record($0) }
        )
        await store.refresh()

        _ = await store.merge(id: "a", expectedHeadOid: "oid") { true }
        await store.awaitRechecks()

        #expect(sleeps.durations == [.seconds(5), .seconds(10)])
        #expect(client.calls == 4)
        #expect(store.merges.isEmpty)
    }

    @Test("a search that never catches up is re-checked three times, then left to the poll")
    func rechecksGiveUp() async {
        let sleeps = Counter()
        let (store, client) = makeStore(listed(makePR("a")), sleep: { sleeps.record($0) })
        await store.refresh()

        _ = await store.merge(id: "a", expectedHeadOid: "oid") { true }
        await store.awaitRechecks()

        #expect(sleeps.durations == [.seconds(5), .seconds(10), .seconds(15)])
        #expect(client.calls == 5)
        #expect(store.merges["a"] == .merged)
    }

    @Test("stopping the store cancels the re-checks")
    func stopCancelsRechecks() async {
        let (store, client) = makeStore(listed(makePR("a")), sleep: Self.parked)
        await store.refresh()

        _ = await store.merge(id: "a", expectedHeadOid: "oid") { true }
        store.stop()
        await store.awaitRechecks()

        #expect(client.calls == 2)
    }
}
