import Foundation
import Observation

/// Which source a card came from, and the drag payload that carries it.
public enum BoardCardID: Hashable, Sendable {
    case jira(String)
    case project(String)

    /// Strings dropped from other apps parse to nil.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "jira":    self = .jira(parts[1])
        case "project": self = .project(parts[1])
        default:        return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .jira(let key):  return "jira:\(key)"
        case .project(let id): return "project:\(id)"
        }
    }
}

public struct BoardCard: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        case jira
        case github(project: String)
    }

    public let id: BoardCardID
    public let source: Source
    /// `ACME-123` for Jira, `repo#42` for GitHub.
    public let reference: String
    /// What Copy ID copies: the key, or `owner/repo#42`, unambiguous across repositories.
    public let copyID: String
    public let title: String
    public let statusName: String
    public let typeName: String
    public let priority: JiraPriority
    public let tint: ReadinessTint
    public let lane: BoardLane
    public let createdAt: Date?
    public let finishedAt: Date?
    /// Nil for Jira, whose link needs the signed-in site.
    public let url: URL?
    public let links: [LinkedPullRequest]
    /// Nil where there is nothing to look up: a card that is itself a pull request.
    public let linkState: IssueLinkState?

    public var typeLabel: String { JiraIssueType.shortName(for: typeName) }
    public var typeTint: ReadinessTint { JiraIssueType.tint(for: typeName) }

    static func precedes(_ one: BoardCard, _ other: BoardCard) -> Bool {
        guard one.priority.order == other.priority.order else {
            return one.priority.order < other.priority.order
        }
        let created = one.createdAt ?? .distantPast
        let otherCreated = other.createdAt ?? .distantPast
        return created == otherCreated ? one.reference < other.reference : created > otherCreated
    }

    static func finishedFirst(_ one: BoardCard, _ other: BoardCard) -> Bool {
        let finished = one.finishedAt ?? .distantPast
        let otherFinished = other.finishedAt ?? .distantPast
        return finished == otherFinished ? one.reference < other.reference : finished > otherFinished
    }
}

public struct BoardColumn: Sendable, Equatable, Identifiable {
    public let lane: BoardLane
    public let cards: [BoardCard]

    public var title: String { lane.title }
    public var id: String { title }
    public var showsPriority: Bool { lane != .done }
}

/// Jira issues and GitHub Project items on one board of shared columns. Each
/// source keeps its own store, fetch and moves; this only composes them.
@MainActor
@Observable
public final class BoardStore {

    public let jira: JiraStore
    public let projects: ProjectStore

    /// No refetch: this changes how the cards in hand are drawn.
    public var layout: JiraLayout {
        didSet {
            guard layout != oldValue else { return }
            preferences.setJiraLayout(layout)
        }
    }

    /// Deliberately not persisted: a filter still in force on the next launch,
    /// with nothing on screen to say so, reads as a board that has broken.
    public var searchQuery = ""

    public private(set) var expanded: Set<BoardCardID> = []

    private let preferences: PreferenceStoring
    private let now: @Sendable () -> Date

    public init(
        jira: JiraStore,
        projects: ProjectStore,
        preferences: PreferenceStoring = UserDefaultsPreferences(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.jira = jira
        self.projects = projects
        self.preferences = preferences
        self.now = now
        self.layout = preferences.jiraLayout()
    }

    /// Lives on `JiraStore`, whose query it shapes; GitHub's Done is filtered here.
    public var window: JiraWindow {
        get { jira.window }
        set { jira.window = newValue }
    }

    public var isConfigured: Bool { jira.isConfigured || projects.isConfigured }

    // MARK: - Cards

    /// Every card on a column before the search, by lane.
    public var allCards: [BoardLane: [BoardCard]] {
        var lanes: [BoardLane: [BoardCard]] = [:]
        for card in jiraCards + projectCards {
            lanes[card.lane, default: []].append(card)
        }
        return lanes.mapValues { cards in
            cards.first?.lane == .done
                ? cards.sorted(by: BoardCard.finishedFirst)
                : cards.sorted(by: BoardCard.precedes)
        }
    }

    public var columns: [BoardColumn] {
        let cards = allCards
        let terms = BoardSearch.terms(in: searchQuery)
        return BoardLane.allCases
            .filter { $0 != .done || window != .off }
            .map { lane in
                BoardColumn(
                    lane: lane,
                    cards: (cards[lane] ?? []).filter { BoardSearch.matches($0, terms: terms) }
                )
            }
    }

    public var visibleCount: Int { columns.reduce(0) { $0 + $1.cards.count } }

    /// Every card on a column whatever the search, for the tab's badge.
    public var cardCount: Int { allCards.values.reduce(0) { $0 + $1.count } }

    public func card(_ id: BoardCardID) -> BoardCard? {
        allCards.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    private var jiraCards: [BoardCard] {
        let groups = jira.groups
        let lanes: [(BoardLane, [JiraIssue])] = [
            (.toDo, groups.toDo), (.inProgress, groups.inProgress), (.reviewing, groups.reviewing),
            (.testing, groups.testing), (.done, groups.done),
        ]
        return lanes.flatMap { lane, issues in
            issues.map { issue in
                let links = jira.links[issue.key] ?? []
                return BoardCard(
                    id: .jira(issue.key), source: .jira, reference: issue.key, copyID: issue.key,
                    title: issue.summary,
                    statusName: issue.statusName, typeName: issue.issueType, priority: issue.priority,
                    tint: issue.statusCategory.tint, lane: lane, createdAt: issue.createdAt,
                    finishedAt: issue.categoryChangedAt, url: nil, links: links,
                    linkState: jira.linkState(for: issue.key)
                )
            }
        }
    }

    /// Done is filtered against the window by when the Status was set, the
    /// way Jira's is by when the category changed. A card being moved counts as
    /// finishing now, as Jira's does.
    private var projectCards: [BoardCard] {
        projects.items.compactMap { item in
            guard let lane = projects.lane(of: item) else { return nil }
            let moving = projects.moves[item.id] != nil
            let finishedAt = moving ? now() : item.statusChangedAt
            if lane == .done, !window.includes(finishedAt: finishedAt, now: now()) { return nil }
            let project = projects.project(for: item)
            let statusName = project?.options.first { $0.id == item.statusOptionID }?.name
                ?? item.statusName ?? "No Status"
            return BoardCard(
                id: .project(item.id), source: .github(project: project?.title ?? ""),
                reference: item.reference,
                copyID: PullRequestReference.id(repo: item.repo, number: item.number),
                title: item.title, statusName: statusName,
                typeName: item.typeName, priority: .unset, tint: lane.tint, lane: lane,
                createdAt: item.createdAt, finishedAt: finishedAt, url: item.url, links: item.links,
                linkState: item.isPullRequest ? nil : (item.links.isEmpty ? IssueLinkState.none : .linked)
            )
        }
    }

    // MARK: - State

    /// The one flag the pane and the popover's width both read.
    public var showsBoard: Bool {
        layout == .board && isConfigured && visibleCount > 0
    }

    private struct SourceState {
        let name: String
        let lastError: PRMasterError?
        let lastSuccessfulFetch: Date?
    }

    private var configuredSources: [SourceState] {
        var sources: [SourceState] = []
        if jira.isConfigured {
            sources.append(SourceState(name: "Jira", lastError: jira.lastError, lastSuccessfulFetch: jira.lastSuccessfulFetch))
        }
        if projects.isConfigured {
            sources.append(SourceState(
                name: "GitHub Projects", lastError: projects.lastError,
                lastSuccessfulFetch: projects.lastSuccessfulFetch
            ))
        }
        return sources
    }

    /// Failed when every source that is set up failed, or when nothing at all is
    /// on the board and one of them failed: an empty Jira says nothing about a
    /// GitHub board that never answered. Loading until each source has answered
    /// one way or the other.
    public var paneState: PaneState {
        let sources = configuredSources
        let failed = sources.compactMap(\.lastError)
        let allFailed = !sources.isEmpty && failed.count == sources.count
        let waiting = sources.contains { $0.lastSuccessfulFetch == nil && $0.lastError == nil }
        let shown = visibleCount
        return PaneState.resolve(
            rowCount: shown,
            hiddenCount: jira.issues.count + projects.items.count - shown,
            lastError: allFailed || cardCount == 0 ? failed.first : nil,
            lastSuccessfulFetch: waiting ? nil : sources.compactMap(\.lastSuccessfulFetch).max()
        )
    }

    /// One line per source that failed, so an actionable reason such as the
    /// missing project scope is never hidden behind another source's.
    public var failureLines: [String] {
        configuredSources.compactMap { source in
            source.lastError.map { "Couldn't reach \(source.name) — \($0.localizedDescription)" }
        }
    }

    /// The pane draws a whole-board failure itself, so these are only the
    /// failures beside cards that did load.
    public var sourceFailures: [String] {
        paneState == .failed ? [] : failureLines
    }

    // MARK: - Expansion

    public func isExpanded(_ id: BoardCardID) -> Bool { expanded.contains(id) }

    public func toggle(_ id: BoardCardID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    // MARK: - Moving

    public func canMove(_ card: BoardCard) -> Bool {
        switch card.id {
        case .jira:    return jira.canMove
        case .project: return projects.canMove
        }
    }

    public func isMoving(_ id: BoardCardID) -> Bool {
        switch id {
        case .jira(let key):  return jira.isMoving(key)
        case .project(let id): return projects.isMoving(id)
        }
    }

    public func move(_ id: BoardCardID, to lane: BoardLane) async {
        switch id {
        case .jira(let key):  await jira.move(key, to: lane)
        case .project(let id): await projects.move(id, to: lane)
        }
    }

    public var moveFailures: [String] {
        [jira.lastMoveFailure, projects.lastMoveFailure].compactMap { $0 }
    }

    public func dismissMoveFailures() {
        jira.dismissMoveFailure()
        projects.dismissMoveFailure()
    }

    // MARK: - Lifecycle

    public func refresh() async {
        await jira.refresh()
        await projects.refresh()
    }

    public func start() {
        jira.start()
        projects.start()
    }

    public func stop() {
        jira.stop()
        projects.stop()
    }
}

extension BoardLane {
    /// For GitHub cards, which have no status category of their own.
    public var tint: ReadinessTint {
        switch self {
        case .toDo:                            return .gray
        case .inProgress, .reviewing, .testing: return .blue
        case .done:                            return .green
        }
    }
}
