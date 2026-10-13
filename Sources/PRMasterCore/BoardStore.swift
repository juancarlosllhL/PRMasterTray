import Foundation
import Observation

/// Which source a card came from, and the drag payload that carries it.
public enum BoardCardID: Hashable, Sendable {
    case jira(String)
    case project(String)
    /// A Jira issue and the GitHub issue migrated from it, drawn as one card.
    case paired(key: String, item: String)

    /// Strings dropped from other apps parse to nil.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "jira":    self = .jira(parts[1])
        case "project": self = .project(parts[1])
        case "paired":
            let ids = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
            guard ids.count == 2 else { return nil }
            self = .paired(key: ids[0], item: ids[1])
        default:        return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .jira(let key):  return "jira:\(key)"
        case .project(let id): return "project:\(id)"
        case .paired(let key, let item): return "paired:\(key)/\(item)"
        }
    }
}

public struct BoardCard: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Hashable {
        case jira
        case github(project: String)
    }

    public let id: BoardCardID
    /// Jira first when a card is both.
    public let sources: [Source]
    /// `ACME-123` for Jira and for a pair, `repo#42` for GitHub.
    public let reference: String
    /// The GitHub `repo#42` of a pair.
    public let pairedReference: String?
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
        let copies = migratedCopies
        var lanes: [BoardLane: [BoardCard]] = [:]
        for card in jiraCards(except: copies) + projectCards(pairing: copies) {
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

    /// Item id to the Jira issue it was copied from, first copy per key. Pull requests
    /// are left out: `[ACME-123]` on a pull request names the work, not a copy of it.
    private var migratedCopies: [String: JiraIssue] {
        var issues = Dictionary(jira.issues.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var copies: [String: JiraIssue] = [:]
        for item in projects.items where !item.isPullRequest {
            guard let key = JiraIssueKey.leading(in: item.title)?.key,
                  let issue = issues.removeValue(forKey: key)
            else { continue }
            copies[item.id] = issue
        }
        return copies
    }

    private func jiraCards(except copies: [String: JiraIssue]) -> [BoardCard] {
        let paired = Set(copies.values.map(\.key))
        let groups = jira.groups
        let lanes: [(BoardLane, [JiraIssue])] = [
            (.toDo, groups.toDo), (.inProgress, groups.inProgress), (.reviewing, groups.reviewing),
            (.testing, groups.testing), (.done, groups.done),
        ]
        return lanes.flatMap { lane, issues in
            issues.filter { !paired.contains($0.key) }.map { issue in
                let links = jira.links[issue.key] ?? []
                return BoardCard(
                    id: .jira(issue.key), sources: [.jira], reference: issue.key, pairedReference: nil,
                    copyID: issue.key,
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
    private func projectCards(pairing copies: [String: JiraIssue]) -> [BoardCard] {
        projects.items.compactMap { item in
            guard let lane = projects.lane(of: item) else { return nil }
            let moving = projects.moves[item.id] != nil
            let finishedAt = moving ? now() : item.statusChangedAt
            if lane == .done, !window.includes(finishedAt: finishedAt, now: now()) { return nil }
            let project = projects.project(for: item)
            let statusName = project?.options.first { $0.id == item.statusOptionID }?.name
                ?? item.statusName ?? "No Status"
            let card = BoardCard(
                id: .project(item.id), sources: [.github(project: project?.title ?? "")],
                reference: item.reference, pairedReference: nil,
                copyID: PullRequestReference.id(repo: item.repo, number: item.number),
                title: item.title, statusName: statusName,
                typeName: item.typeName, priority: .unset, tint: lane.tint, lane: lane,
                createdAt: item.createdAt, finishedAt: finishedAt, url: item.url, links: item.links,
                linkState: item.isPullRequest ? nil : (item.links.isEmpty ? IssueLinkState.none : .linked)
            )
            return copies[item.id].map { paired(card, item: item, issue: $0) } ?? card
        }
    }

    /// GitHub places and opens the card. Jira's priority, type and age stand,
    /// since the copy's were set on migration day.
    private func paired(_ card: BoardCard, item: ProjectItem, issue: JiraIssue) -> BoardCard {
        let jiraLinks = jira.links[issue.key] ?? []
        let links = jiraLinks + card.links.filter { pull in !jiraLinks.contains { $0.url == pull.url } }
        let status = jira.lane(of: issue) == card.lane
            ? card.statusName
            : "\(card.statusName) · Jira: \(issue.statusName)"
        return BoardCard(
            id: .paired(key: issue.key, item: item.id), sources: [.jira] + card.sources,
            reference: issue.key, pairedReference: card.reference, copyID: card.copyID,
            title: JiraIssueKey.leading(in: item.title)?.title ?? item.title,
            statusName: status, typeName: issue.issueType, priority: issue.priority, tint: card.tint,
            lane: card.lane, createdAt: issue.createdAt, finishedAt: card.finishedAt, url: card.url,
            links: links, linkState: links.isEmpty ? jira.linkState(for: issue.key) : .linked
        )
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
        case .jira:              return jira.canMove
        case .project, .paired:  return projects.canMove
        }
    }

    public func isMoving(_ id: BoardCardID) -> Bool {
        switch id {
        case .jira(let key):  return jira.isMoving(key)
        case .project(let id): return projects.isMoving(id)
        case .paired(let key, let item): return jira.isMoving(key) || projects.isMoving(item)
        }
    }

    public func move(_ id: BoardCardID, to lane: BoardLane) async {
        switch id {
        case .jira(let key):  await jira.move(key, to: lane)
        case .project(let id): await projects.move(id, to: lane)
        case .paired(let key, let item):
            // Together: Jira may sit on its form while GitHub has already moved the card.
            async let github: Void = projects.move(item, to: lane)
            await jira.move(key, to: lane)
            await github
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
