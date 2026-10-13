import Foundation
import Observation

public protocol ProjectFetching: Sendable {
    func fetchProjects() async throws -> [GitHubProject]
    func fetchProjectItems(projectID: String) async throws -> [ProjectItem]
}

public protocol ProjectItemMoving: Sendable {
    func setStatus(project: String, item: String, field: String, option: String) async throws
}

extension GitHubClient: ProjectFetching, ProjectItemMoving {}

/// The GitHub half of the board: which projects there are, which are shown,
/// where their Status options land, and the items assigned to you on them.
@MainActor
@Observable
public final class ProjectStore {

    public private(set) var projects: [GitHubProject]
    public private(set) var items: [ProjectItem] = []
    public private(set) var lastError: PRMasterError?
    /// Separate from `lastError`: a failed discovery leaves the known boards usable.
    public private(set) var discoveryError: PRMasterError?
    public private(set) var lastSuccessfulFetch: Date?
    public private(set) var isRefreshing = false
    public private(set) var moves: [String: PendingMove] = [:]
    public private(set) var lastMoveFailure: String?
    public private(set) var selection: ProjectSelection
    public private(set) var laneMap: ProjectLaneMap

    /// The refetch a selection change started, so tests can wait for it.
    private(set) var pendingRefresh: Task<Void, Never>?

    private static let intervals: [Duration] = [.seconds(60), .seconds(120), .seconds(300)]

    private let client: ProjectFetching?
    /// `nil` for fixtures, so fake cards can never write to GitHub.
    private let mover: ProjectItemMoving?
    private let preferences: PreferenceStoring
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var refreshGeneration = 0
    /// Set when a refresh is asked for while one runs, so the running one goes
    /// round again rather than the new board waiting for the next poll.
    private var refreshRequested = false
    private var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?

    public init(
        client: ProjectFetching?,
        mover: ProjectItemMoving? = nil,
        preferences: PreferenceStoring = UserDefaultsPreferences(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.mover = mover
        self.preferences = preferences
        self.now = now
        self.sleep = sleep
        self.projects = preferences.knownProjects()
        self.selection = preferences.projectSelection()
        self.laneMap = preferences.projectLaneMap()
    }

    /// Selected, and with a Status field: a board without one has no columns.
    public var shownProjects: [GitHubProject] {
        projects.filter { selection.shows($0) && $0.hasStatus }
    }

    public var isConfigured: Bool { client != nil && !shownProjects.isEmpty }
    public var canMove: Bool { mover != nil }

    var currentInterval: Duration {
        Self.intervals[min(consecutiveFailures, Self.intervals.count - 1)]
    }

    // MARK: - Settings

    public func setShown(_ project: GitHubProject, _ shown: Bool) {
        selection.set(project, shown: shown)
        preferences.setProjectSelection(selection)
        let shownIDs = Set(shownProjects.map(\.id))
        items = items.filter { shownIDs.contains($0.projectID) }
        guard isConfigured else {
            stop()
            lastError = nil
            return
        }
        if pollTask == nil {
            start()
            pendingRefresh = pollTask
        } else {
            pendingRefresh = Task { await refresh() }
        }
    }

    /// No refetch: this changes where items in hand are drawn, not which were asked for.
    public func setChoice(_ choice: LaneChoice, option: String, in project: GitHubProject) {
        laneMap.set(choice, optionID: option, in: project.id)
        preferences.setProjectLaneMap(laneMap)
    }

    public func choice(for option: StatusOption?, in project: GitHubProject) -> LaneChoice {
        laneMap.choice(optionID: option?.id, name: option?.name, in: project.id)
    }

    // MARK: - Reading

    public func project(for item: ProjectItem) -> GitHubProject? {
        projects.first { $0.id == item.projectID }
    }

    /// The board's current name for the option, so a renamed column is guessed afresh.
    public func lane(of item: ProjectItem) -> BoardLane? {
        if let moving = moves[item.id] { return moving.lane }
        let name = project(for: item)?.options.first { $0.id == item.statusOptionID }?.name
        return laneMap.lane(optionID: item.statusOptionID, name: name ?? item.statusName, in: item.projectID)
    }

    public func isMoving(_ itemID: String) -> Bool {
        moves[itemID].map { $0.settledAfter == nil } ?? false
    }

    // MARK: - Discovery

    /// A selected board GitHub stopped listing is kept: recent projects rotate
    /// out of its answer, and a board you chose must not go with them.
    public func discover() async {
        guard let client else { return }
        do {
            let found = try await client.fetchProjects()
            let foundIDs = Set(found.map(\.id))
            let kept = projects.filter { selection.shows($0) && !foundIDs.contains($0.id) }
            projects = found + kept
            preferences.setKnownProjects(projects)
            discoveryError = nil
        } catch {
            discoveryError = Self.asDomainError(error)
        }
    }

    // MARK: - Refresh

    /// A board that fails keeps its last items, so one broken board cannot
    /// empty the others' cards.
    public func refresh() async {
        guard let client else { return }
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            await refreshOnce(client)
        } while refreshRequested
    }

    private func refreshOnce(_ client: ProjectFetching) async {
        let asked = shownProjects
        guard !asked.isEmpty else { return }
        refreshGeneration += 1
        let generation = refreshGeneration

        var collected: [ProjectItem] = []
        var failure: PRMasterError?
        var answered = 0
        for project in asked {
            do {
                collected += try await client.fetchProjectItems(projectID: project.id)
                answered += 1
            } catch {
                failure = Self.asDomainError(error)
                collected += items.filter { $0.projectID == project.id }
            }
        }

        let stillShown = Set(shownProjects.map(\.id))
        items = collected.filter { stillShown.contains($0.projectID) }
        moves = moves.filter { $0.value.settledAfter.map { $0 >= generation } ?? true }
        lastError = failure
        if answered > 0 { lastSuccessfulFetch = now() }
        consecutiveFailures = failure == nil ? 0 : consecutiveFailures + 1
    }

    // MARK: - Moving

    public func move(_ itemID: String, to lane: BoardLane) async {
        guard let mover, !isMoving(itemID),
              let item = items.first(where: { $0.id == itemID }),
              let project = project(for: item),
              self.lane(of: item) != lane
        else { return }

        lastMoveFailure = nil
        guard let field = project.statusFieldID, let option = laneMap.target(for: lane, in: project) else {
            lastMoveFailure = "\(project.title) has no Status option in \(lane.title). "
                + "Map one under Settings, Board."
            return
        }

        moves[itemID] = PendingMove(lane: lane, settledAfter: nil)
        do {
            try await mover.setStatus(project: project.id, item: itemID, field: field, option: option.id)
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index] = items[index].with(status: option, at: now())
            }
            moves[itemID]?.settledAfter = refreshGeneration
        } catch {
            moves[itemID] = nil
            let reason = (error as? PRMasterError)?.errorDescription ?? error.localizedDescription
            lastMoveFailure = "Couldn't move \(item.reference) — \(reason)"
        }
        await refresh()
    }

    public func dismissMoveFailure() {
        lastMoveFailure = nil
    }

    private static func asDomainError(_ error: any Error) -> PRMasterError {
        error as? PRMasterError ?? .decoding(String(describing: error))
    }

    // MARK: - Polling

    func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await sleep(currentInterval)
            } catch {
                return
            }
        }
    }

    public func start() {
        guard pollTask == nil, isConfigured else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}
