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
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

/// Serves a scripted sequence of results, one per refresh.
private final class StubClient: PullRequestFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[PullRequest], PRMasterError>]
    private(set) var calls = 0

    init(_ results: [Result<[PullRequest], PRMasterError>]) { self.results = results }

    func fetchMyPullRequests() async throws -> [PullRequest] {
        let next: Result<[PullRequest], PRMasterError> = lock.withLock {
            calls += 1
            return results.isEmpty ? .success([]) : results.removeFirst()
        }
        return try next.get()
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

    init(
        autoUpdate: Bool = true,
        filter: PRFilter = PRFilter(),
        theme: AppTheme = .system,
        monochrome: Bool = false
    ) {
        enabled = autoUpdate
        stored = filter
        storedTheme = theme
        storedMonochrome = monochrome
    }

    func autoUpdateEnabled() -> Bool { lock.withLock { enabled } }
    func setAutoUpdateEnabled(_ value: Bool) { lock.withLock { enabled = value } }
    func filter() -> PRFilter { lock.withLock { stored } }
    func setFilter(_ value: PRFilter) { lock.withLock { stored = value } }
    func theme() -> AppTheme { lock.withLock { storedTheme } }
    func setTheme(_ value: AppTheme) { lock.withLock { storedTheme = value } }
    func monochromeEnabled() -> Bool { lock.withLock { storedMonochrome } }
    func setMonochromeEnabled(_ value: Bool) { lock.withLock { storedMonochrome = value } }
}

@MainActor
@Suite("PRStore")
struct PRStoreTests {

    private func makeStore(
        _ results: [Result<[PullRequest], PRMasterError>],
        notified: Set<String> = [],
        notifierFails: Bool = false,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> (PRStore, StubClient, SpyNotifier, MemoryIDStore) {
        let client = StubClient(results)
        let notifier = SpyNotifier(failing: notifierFails)
        let idStore = MemoryIDStore(notified)
        let store = PRStore(
            client: client,
            notifier: notifier,
            idStore: idStore,
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
