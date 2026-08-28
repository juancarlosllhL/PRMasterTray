import Foundation
import Observation

/// Observable state behind the "waiting on your teams" section.
///
/// Beside `PRStore` rather than inside it, on the grounds `AppearanceStore`
/// documents for itself. These are other people's pull requests, fetched by their
/// own pair of requests, failing on their own account — and a failure here must
/// never raise the stale banner over the user's own list, which is what a fourth
/// `last…Failure` field on a class that already carries three would invite.
///
/// One thing is deliberately *not* owned here: `PRFilter`. That belongs to
/// `PRStore`, and `visible(under:)` takes it rather than keeping a second copy,
/// so there is one owner of "which repositories does this user want to see" and
/// no way for the two to disagree.
@MainActor
@Observable
public final class ReviewStore {

    /// The last *successful* snapshot, deduplicated across teams and ordered by
    /// last activity. Deliberately not cleared on failure: a wifi blip must not
    /// read as nothing waiting on any of your teams.
    public private(set) var requests: [ReviewRequest] = []
    /// Every team the user belongs to, including the ones they have switched off —
    /// the settings list needs all of them, and a team hidden from the section
    /// still has to be findable in order to switch back on.
    public private(set) var teams: [Team] = []
    /// What GitHub reports pending per team, by `combinedSlug`, including for
    /// teams whose rows were never fetched. That is the number the settings list
    /// shows beside a switched-off team, so it can say what enabling it costs.
    public private(set) var pendingCounts: [String: Int] = [:]
    public private(set) var lastSuccessfulFetch: Date?
    /// Set when either read failed. One field for both, because the section has
    /// one story to tell — but a *discovery* failure does not stop the search
    /// running against the cached team list, so this can be set while rows are
    /// still arriving.
    public private(set) var lastError: PRMasterError?
    public private(set) var isRefreshing = false
    /// Rows with an approval in flight. This app writes to somebody else's pull
    /// request here, so it says so while it is happening.
    public private(set) var approvingIDs: Set<String> = []

    /// How far back the section reaches.
    ///
    /// Unlike `PRStore.staleThreshold` this cannot be answered from the snapshot
    /// in hand: widening it asks for pull requests the last search never
    /// requested. So it persists and then kicks a refresh.
    public var window: ReviewWindow {
        didSet {
            guard window != oldValue else { return }
            preferences.setReviewWindow(window)
            // Emptied on the spot. Waiting for a round trip to clear a section
            // the user just switched off reads as the switch not working.
            if window == .off {
                requests = []
                pendingCounts = [:]
                lastError = nil
            }
            Task { await refresh() }
        }
    }

    /// Which teams are listed. Persists and refetches rather than re-deriving:
    /// a team that was switched off was asked at `first: 0`, so its rows are not
    /// in hand to re-derive from.
    public var teamFilter: TeamFilter {
        didSet {
            guard teamFilter != oldValue else { return }
            preferences.setTeamFilter(teamFilter)
            Task { await refresh() }
        }
    }

    /// 60s normally, stepping up while GitHub is unreachable, the same ladder
    /// `PRStore` climbs.
    private static let intervals: [Duration] = [.seconds(60), .seconds(120), .seconds(300)]

    /// `nil` under a debug override, where there is nothing worth asking: a
    /// fixture's team slugs name teams that may not exist, and the rows would
    /// carry real node IDs pointing at real pull requests.
    private let client: ReviewRequestFetching?
    /// `nil` under a debug override. Absent rather than merely refusing, so the
    /// affordance can be hidden instead of offering an action that will be turned
    /// down — see `ApproveCoordinator` for why there is no no-op stand-in.
    private let approver: ApproveCoordinator?
    private let preferences: PreferenceStoring
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?

    public init(
        client: ReviewRequestFetching?,
        approver: ApproveCoordinator? = nil,
        preferences: PreferenceStoring = UserDefaultsPreferences(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.client = client
        self.approver = approver
        self.preferences = preferences
        self.now = now
        self.sleep = sleep
        self.window = preferences.reviewWindow()
        self.teamFilter = preferences.teamFilter()
        // Yesterday's list beats no list: the settings window has something to
        // show before the first fetch lands, and a failed discovery has something
        // to search with.
        self.teams = preferences.knownTeams()
    }

    /// How long the loop will wait before the next refresh.
    var currentInterval: Duration {
        Self.intervals[min(consecutiveFailures, Self.intervals.count - 1)]
    }

    // MARK: - Reading

    /// The rows to draw, given the repository filter `PRStore` owns.
    ///
    /// A function rather than a stored property because it depends on state this
    /// class does not own, and on the clock. Both callers read it inside a view
    /// body, where `@Observable` tracks the reads either way.
    ///
    /// The window is applied here as well as in the search. A row can age past
    /// the limit between polls, and deriving rather than snapshotting means the
    /// section goes quiet by itself instead of showing something the next search
    /// would not return.
    public func visible(under filter: PRFilter) -> [ReviewRequest] {
        let instant = now()
        return filter.apply(to: requests)
            .filter { window.includes(createdAt: $0.createdAt, now: instant) }
    }

    /// What GitHub reports pending for one team, or `nil` when it did not answer.
    /// Absent is not zero — see `ReviewSnapshot`.
    public func pendingCount(for team: Team) -> Int? {
        pendingCounts[team.combinedSlug]
    }

    /// Whether the section is showing fewer rows than GitHub says are pending, so
    /// it can say so rather than truncating in silence.
    ///
    /// Judged per team and only over the teams that are switched on: a disabled
    /// team's count is real, but its rows were never fetched, so counting it here
    /// would make every section with a disabled team claim to be truncated.
    public func isTruncated(under filter: PRFilter) -> Bool {
        let shown = visible(under: filter)
        return teamFilter.enabled(from: teams).contains { team in
            guard let pending = pendingCounts[team.combinedSlug] else { return false }
            return shown.filter { $0.teams.contains(team) }.count < pending
        }
    }

    // MARK: - Refresh

    public func refresh() async {
        // Four call sites reach here: the poll loop, opening the popover, waking,
        // and either setting changing. `@MainActor` methods are reentrant across
        // `await`, so without this the slower of two overlapping fetches wins and
        // can restore stale data — the bug `PRStore.refresh` documents.
        guard !isRefreshing else { return }
        // Nothing to ask, and nothing to ask it with. Checked before the flag so
        // an off window cannot leave the indicator spinning.
        guard window != .off, let client else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        var failure: PRMasterError?

        do {
            let discovered = try await client.fetchTeams()
            teams = discovered
            preferences.setKnownTeams(discovered)
        } catch {
            // Reported, but not fatal: the cached list is usually still right, and
            // teams change rarely. Recorded even when the rows arrive anyway, or a
            // missing `read:org` scope would stay invisible for as long as the
            // cache held out.
            failure = Self.asDomainError(error)
        }

        // Nothing to fall back on. Searching would ask about no teams and come
        // back empty, which would read as nothing waiting rather than as a
        // lookup that failed.
        guard !teams.isEmpty || failure == nil else {
            lastError = failure
            consecutiveFailures += 1
            return
        }

        do {
            let snapshot = try await client.fetchReviewRequests(
                teams: teams, filter: teamFilter, window: window
            )
            requests = snapshot.requests
            pendingCounts = snapshot.pendingCounts
            lastSuccessfulFetch = now()
        } catch {
            // `requests` and `pendingCounts` are deliberately untouched.
            failure = failure ?? Self.asDomainError(error)
        }

        lastError = failure
        consecutiveFailures = failure == nil ? 0 : consecutiveFailures + 1
    }

    private static func asDomainError(_ error: Error) -> PRMasterError {
        error as? PRMasterError ?? .decoding(String(describing: error))
    }

    // MARK: - Approving

    /// Approves one row, after whatever confirmation the caller supplies.
    ///
    /// The row leaves the list on success rather than waiting for the next poll:
    /// the search excludes anything the user has already reviewed, so the next
    /// refresh would drop it anyway — a minute later, which reads as the button
    /// not having worked.
    public func approve(
        _ request: ReviewRequest,
        confirm: @MainActor () async -> Bool
    ) async -> ApproveOutcome {
        guard let approver else { return .refusedDebugOverride }

        approvingIDs.insert(request.id)
        defer { approvingIDs.remove(request.id) }

        let outcome = await approver.attempt(
            id: request.id,
            // The commit the user was looking at, not whatever is current. It
            // records what was approved rather than guarding it — see
            // `Queries.approvePullRequest`.
            commitOID: request.headRefOid,
            confirm: confirm
        )

        if outcome == .approved {
            requests.removeAll { $0.id == request.id }
        }
        return outcome
    }

    // MARK: - Polling

    /// Refresh, wait, repeat. Exposed for tests so the loop can be driven with an
    /// injected sleep instead of real time.
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
