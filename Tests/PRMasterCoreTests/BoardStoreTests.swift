import Foundation
import Testing
@testable import PRMasterCore

private let now = Date(timeIntervalSince1970: 2_000_000)
private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func jiraIssue(
    _ key: String, _ status: String, _ category: JiraStatusCategory,
    priority: JiraPriority = .medium, type: String = "Task", createdDaysAgo: Double = 1, doneDaysAgo: Double? = nil
) -> JiraIssue {
    JiraIssue(
        key: key, summary: "summary \(key)", statusName: status, statusCategory: category,
        issueType: type, priority: priority, updatedAt: now, createdAt: daysAgo(createdDaysAgo),
        categoryChangedAt: doneDaysAgo.map(daysAgo)
    )
}

private func item(
    _ id: String, _ option: String?, number: Int, createdDaysAgo: Double = 0, changedDaysAgo: Double = 1,
    isPullRequest: Bool = false, links: [LinkedPullRequest] = [], title: String? = nil
) -> ProjectItem {
    ProjectItem(
        id: id, projectID: "PVT_1", number: number, title: title ?? "github \(id)",
        url: URL(string: "https://github.com/acme/widget/issues/\(number)")!, repo: "acme/widget",
        isPullRequest: isPullRequest, typeName: "Task", statusOptionID: option, statusName: nil,
        statusChangedAt: daysAgo(changedDaysAgo), createdAt: daysAgo(createdDaysAgo), links: links
    )
}

private struct FixedIssues: JiraIssueFetching {
    let result: Result<[JiraIssue], PRMasterError>
    func fetchAssignedIssues(within window: JiraWindow) async throws -> [JiraIssue] { try result.get() }
}

private struct FixedLinks: IssueLinkFetching {
    let links: [String: [LinkedPullRequest]]
    func fetchPullRequests(forIssueKeys keys: [String]) async throws -> [String: [LinkedPullRequest]] { links }
}

private final class CountingIssues: JiraIssueFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var fetches = 0
    var count: Int { lock.withLock { fetches } }
    func fetchAssignedIssues(within window: JiraWindow) async throws -> [JiraIssue] {
        lock.withLock { fetches += 1 }
        return []
    }
}

/// Walks To Do to In Progress in one hop.
private final class OneHopJira: JiraIssueMoving, @unchecked Sendable {
    private let lock = NSLock()
    private var moved = false
    private(set) var performed: [String] = []
    private let fields: [JiraField]

    init(fields: [JiraField] = []) { self.fields = fields }

    func transitions(for key: String) async throws -> (JiraStatus, [JiraTransition]) {
        lock.withLock {
            moved
                ? (JiraStatus(name: "In Progress", category: .inProgress), [])
                : (JiraStatus(name: "To Do", category: .toDo), [JiraTransition(
                    id: "11", to: JiraStatus(name: "In Progress", category: .inProgress),
                    isGlobal: false, needsInput: false, fields: fields)])
        }
    }

    func perform(_ transition: JiraTransition, on key: String, values: [String: String]) async throws {
        lock.withLock {
            moved = true
            performed.append(key)
        }
    }
}

private final class ServedProjects: ProjectFetching, ProjectItemMoving, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<[ProjectItem], PRMasterError>
    private var sets: [String] = []
    var moved: [String] { lock.withLock { sets } }

    init(_ result: Result<[ProjectItem], PRMasterError>) { self.result = result }

    func fetchProjects() async throws -> [GitHubProject] { [] }
    func fetchProjectItems(projectID: String) async throws -> [ProjectItem] { try result.get() }
    func setStatus(project: String, item: String, field: String, option: String) async throws {
        lock.withLock { sets.append("\(item)→\(option)") }
    }
}

private let standardItems = [
    item("a", "o-todo", number: 1, createdDaysAgo: 0),
    item("b", "o-review", number: 2),
    item("c", "o-done", number: 3, changedDaysAgo: 2),
    item("d", "o-done", number: 4, changedDaysAgo: 30),
    item("e", "o-blocked", number: 5),
    item("f", nil, number: 6, createdDaysAgo: 3, isPullRequest: true),
]

private let standardIssues = [
    jiraIssue("ACME-1", "To Do", .toDo, createdDaysAgo: 1),
    jiraIssue("ACME-2", "In Progress", .inProgress, priority: .high),
    jiraIssue("ACME-4", "Done", .done, doneDaysAgo: 1),
]

@MainActor
private func makeBoard(
    issues: Result<[JiraIssue], PRMasterError>? = .success(standardIssues),
    items: Result<[ProjectItem], PRMasterError>? = .success(standardItems),
    preferences: MemoryPreferences = MemoryPreferences(),
    jiraMover: JiraIssueMoving? = nil,
    links: [String: [LinkedPullRequest]]? = nil
) async -> (BoardStore, ServedProjects?) {
    if items != nil {
        preferences.setKnownProjects([boardProject()])
        preferences.setProjectSelection(ProjectSelection(enabled: ["PVT_1"]))
    }
    let jira = JiraStore(
        issues: issues.map { FixedIssues(result: $0) }, links: links.map(FixedLinks.init), mover: jiraMover,
        preferences: preferences, now: { now }, sleep: { _ in throw CancellationError() }
    )
    let served = items.map { ServedProjects($0) }
    let projects = ProjectStore(
        client: served, mover: served, preferences: preferences,
        now: { now }, sleep: { _ in throw CancellationError() }
    )
    let board = BoardStore(jira: jira, projects: projects, preferences: preferences, now: { now })
    await board.refresh()
    return (board, served)
}

private func references(_ column: BoardColumn?) -> [String] { column?.cards.map(\.reference) ?? [] }

@Suite("BoardStore columns")
@MainActor
struct BoardStoreColumnTests {

    @Test("columns read left to right in the order the work moves, each carrying its lane")
    func workflowOrder() async {
        let (board, _) = await makeBoard()
        #expect(board.columns.map(\.title) == ["To do", "In progress", "Reviewing", "Testing", "Done"])
        #expect(board.columns.map(\.lane) == BoardLane.allCases)
        #expect(board.columns.allSatisfy { column in column.cards.allSatisfy { $0.lane == column.lane } })
    }

    /// A column that can never fill would read as a bug rather than a window switched off.
    @Test("Done is dropped when its window is off")
    func doneDroppedWhenOff() async {
        let preferences = MemoryPreferences()
        preferences.setJiraWindow(.off)
        let (board, _) = await makeBoard(preferences: preferences)
        #expect(board.columns.map(\.title) == ["To do", "In progress", "Reviewing", "Testing"])
    }

    @Test("an empty column is still drawn, and only Done hides priority")
    func emptyColumnsAndPriority() async {
        let (board, _) = await makeBoard(issues: .success([]), items: nil)
        #expect(board.columns.count == 5)
        #expect(board.columns.allSatisfy { $0.cards.isEmpty })
        #expect(board.columns.map(\.showsPriority) == [true, true, true, true, false])
    }

    @Test("each lane holds cards from both sources, prioritised work first")
    func merged() async {
        let (board, _) = await makeBoard()
        #expect(references(board.columns.first) == ["ACME-1", "widget#1"])
        #expect(references(board.columns.first { $0.lane == .reviewing }) == ["widget#2"])
    }

    @Test("cards of equal priority read newest first, then by reference")
    func newestFirst() async {
        let items = [item("x", "o-todo", number: 9, createdDaysAgo: 5), item("y", "o-todo", number: 8, createdDaysAgo: 1),
                     item("z", "o-todo", number: 7, createdDaysAgo: 1)]
        let (board, _) = await makeBoard(issues: .success([]), items: .success(items))
        #expect(references(board.columns.first) == ["widget#7", "widget#8", "widget#9"])
    }

    @Test("Done reads by when each card finished, across sources")
    func doneOrder() async {
        let (board, _) = await makeBoard()
        #expect(references(board.columns.last) == ["ACME-4", "widget#3"])
    }

    @Test("a GitHub card leaves Done once its Status was set outside the window")
    func doneWindow() async {
        let (board, _) = await makeBoard()
        #expect(!board.columns.flatMap(\.cards).contains { $0.reference == "widget#4" })
    }

    @Test("a GitHub card in a hidden option, or with no Status, is on no column")
    func hiddenOption() async {
        let (board, _) = await makeBoard()
        let shown = board.columns.flatMap(\.cards).map(\.reference)
        #expect(!shown.contains("widget#5"))
        #expect(!shown.contains("widget#6"))
    }

    @Test("a GitHub card names its board and links to GitHub; a Jira card does neither")
    func sources() async throws {
        let (board, _) = await makeBoard()
        let cards = board.columns.flatMap(\.cards)
        let github = try #require(cards.first { $0.reference == "widget#1" })
        let jira = try #require(cards.first { $0.reference == "ACME-1" })
        #expect(github.sources == [.github(project: "Platform Board")])
        #expect(github.url?.absoluteString == "https://github.com/acme/widget/issues/1")
        #expect(github.title == "github a")
        #expect(github.copyID == "acme/widget#1")
        #expect(jira.copyID == "ACME-1")
        #expect(jira.sources == [.jira])
        #expect(jira.url == nil)
        #expect(jira.priority == .medium)
        #expect(github.priority == .unset)
    }

    @Test("a GitHub issue's link state comes from its closing pull requests; a pull request has none")
    func linkStates() async throws {
        let pull = LinkedPullRequest(
            id: "PR_1", number: 10, title: "fix", url: URL(string: "https://github.com/acme/widget/pull/10")!,
            repo: "acme/widget", isPrivate: false, isDraft: false, state: .open
        )
        let items = [item("a", "o-todo", number: 1, links: [pull]), item("b", "o-todo", number: 2),
                     item("f", "o-todo", number: 6, isPullRequest: true)]
        let (board, _) = await makeBoard(issues: .success([]), items: .success(items))
        let cards = board.columns.flatMap(\.cards)
        #expect(cards.first { $0.reference == "widget#1" }?.linkState == .linked)
        #expect(cards.first { $0.reference == "widget#1" }?.links.map(\.number) == [10])
        #expect(cards.first { $0.reference == "widget#2" }?.linkState == IssueLinkState.none)
        #expect(cards.first { $0.reference == "widget#6" }?.linkState == nil)
    }
}

private func pull(_ number: Int) -> LinkedPullRequest {
    LinkedPullRequest(
        id: "PR_\(number)", number: number, title: "fix", url: URL(string: "https://github.com/acme/widget/pull/\(number)")!,
        repo: "acme/widget", isPrivate: false, isDraft: false, state: .open
    )
}

private let migrated = jiraIssue("ACME-1", "To Do", .toDo, priority: .high, type: "Bug", createdDaysAgo: 40)

private func copy(
    _ option: String = "o-review", id: String = "c", number: Int = 7, changedDaysAgo: Double = 1,
    links: [LinkedPullRequest] = [], title: String = "[ACME-1] Ship it"
) -> ProjectItem {
    item(id, option, number: number, changedDaysAgo: changedDaysAgo, links: links, title: title)
}

@Suite("BoardStore pairs a Jira issue with its migrated GitHub copy")
@MainActor
struct BoardStorePairTests {

    @Test("a GitHub issue titled with a Jira key on the board shares that issue's card, placed by GitHub")
    func onePair() async throws {
        let (board, _) = await makeBoard(issues: .success([migrated]), items: .success([copy()]))
        let cards = board.columns.flatMap(\.cards)
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.id == .paired(key: "ACME-1", item: "c"))
        #expect(card.sources == [.jira, .github(project: "Platform Board")])
        #expect(card.reference == "ACME-1")
        #expect(card.pairedReference == "widget#7")
        #expect(card.title == "Ship it")
        #expect(card.lane == .reviewing)
        #expect(card.url?.absoluteString == "https://github.com/acme/widget/issues/7")
        #expect(card.copyID == "acme/widget#7")
    }

    /// The copy was created on migration day and carries no priority, so its own would misorder the lane.
    @Test("age, priority and type come from Jira, which set them when the work began")
    func jiraFacts() async throws {
        let (board, _) = await makeBoard(issues: .success([migrated]), items: .success([copy()]))
        let card = try #require(board.columns.flatMap(\.cards).first)
        #expect(card.createdAt == daysAgo(40))
        #expect(card.priority == .high)
        #expect(card.typeName == "Bug")
    }

    @Test("the status also names Jira's while the two tools disagree on the column")
    func statusWhenLanesDiffer() async throws {
        let (apart, _) = await makeBoard(issues: .success([migrated]), items: .success([copy("o-review")]))
        #expect(apart.columns.flatMap(\.cards).first?.statusName == "In Review · Jira: To Do")
        let (agreeing, _) = await makeBoard(issues: .success([migrated]), items: .success([copy("o-todo")]))
        #expect(agreeing.columns.flatMap(\.cards).first?.statusName == "Todo")
    }

    @Test("pull requests from both tools are listed once")
    func linksFromBoth() async throws {
        let (board, _) = await makeBoard(
            issues: .success([migrated]), items: .success([copy(links: [pull(10), pull(11)])]),
            links: ["ACME-1": [pull(11), pull(12)]]
        )
        let card = try #require(board.columns.flatMap(\.cards).first)
        #expect(card.links.map(\.number).sorted() == [10, 11, 12])
        #expect(card.linkState == .linked)
    }

    /// GitHub alone would say "none"; only Jira's lookup knows whether it could check.
    @Test("with no pull request on either side, the card reads Jira's lookup")
    func linkStateFromJira() async throws {
        let (board, _) = await makeBoard(issues: .success([migrated]), items: .success([copy()]))
        #expect(board.columns.flatMap(\.cards).first?.linkState == .unknown)
    }

    @Test("a pull request titled with the key, an unknown key, or a key later in the title keeps its own card")
    func notCopies() async throws {
        let items = [
            item("p", "o-review", number: 8, isPullRequest: true, title: "[ACME-1] fix it"),
            item("q", "o-todo", number: 9, title: "[ACME-99] elsewhere"),
            item("r", "o-todo", number: 10, title: "Follow up on ACME-1"),
        ]
        let (board, _) = await makeBoard(issues: .success([migrated]), items: .success(items))
        let cards = board.columns.flatMap(\.cards)
        #expect(Set(cards.map(\.reference)) == ["ACME-1", "widget#8", "widget#9", "widget#10"])
        #expect(cards.first { $0.reference == "ACME-1" }?.sources == [.jira])
        #expect(cards.first { $0.reference == "widget#9" }?.title == "[ACME-99] elsewhere")
    }

    @Test("a copy GitHub keeps off the board takes its Jira card with it", arguments: [("o-blocked", 1.0), ("o-done", 30.0)])
    func hiddenWithCopy(option: String, changedDaysAgo: Double) async {
        let (board, _) = await makeBoard(
            issues: .success([migrated]), items: .success([copy(option, changedDaysAgo: changedDaysAgo)])
        )
        #expect(board.cardCount == 0)
    }

    @Test("the search finds a pair by either tool's reference or by its title", arguments: ["ACME-1", "widget#7", "ship"])
    func search(query: String) async {
        let (board, _) = await makeBoard(issues: .success([migrated]), items: .success([copy()]))
        board.searchQuery = query
        #expect(board.visibleCount == 1)
        #expect(board.cardCount == 1)
    }

    @Test("of two GitHub issues naming one key, the first pairs and the second keeps its own card")
    func secondCopy() async {
        let items = [copy(id: "c", number: 7), copy("o-todo", id: "d", number: 8, title: "[ACME-1] Ship it too")]
        let (board, _) = await makeBoard(issues: .success([migrated]), items: .success(items))
        let ids = board.columns.flatMap(\.cards).map(\.id)
        #expect(Set(ids) == [.paired(key: "ACME-1", item: "c"), .project("d")])
    }

    private let pair = BoardCardID.paired(key: "ACME-1", item: "c")

    @Test("moving a pair moves it in GitHub and in Jira")
    func movesBoth() async {
        let jiraMover = OneHopJira()
        let (board, served) = await makeBoard(
            issues: .success([migrated]), items: .success([copy("o-todo")]), jiraMover: jiraMover
        )
        await board.move(pair, to: .inProgress)
        #expect(served?.moved == ["c→o-progress"])
        #expect(jiraMover.performed == ["ACME-1"])
    }

    /// Jira's form stays open for as long as the user takes over it.
    @Test("GitHub moves the card while Jira's form is open, and the pair reads as moving until Jira is done")
    func movesWhileJiraAsks() async {
        let remark = JiraField(id: "customfield_10170", name: "Remark", kind: .richText)
        let (board, served) = await makeBoard(
            issues: .success([migrated]), items: .success([copy("o-todo")]), jiraMover: OneHopJira(fields: [remark])
        )
        let moving = Task { await board.move(pair, to: .inProgress) }
        for _ in 0..<10_000 where board.jira.fieldRequest == nil || served?.moved.isEmpty == true {
            await Task.yield()
        }
        #expect(served?.moved == ["c→o-progress"])
        #expect(board.isMoving(pair))
        board.jira.cancelFields()
        await moving.value
        #expect(!board.isMoving(pair))
    }

    @Test("a side that cannot finish the move says so, and the other still moves")
    func oneSideStops() async {
        let (board, served) = await makeBoard(
            issues: .success([migrated]), items: .success([copy("o-todo")]), jiraMover: OneHopJira()
        )
        await board.move(pair, to: .reviewing)
        #expect(served?.moved == ["c→o-review"])
        #expect(board.moveFailures.count == 1)
        #expect(board.moveFailures.first?.hasPrefix("ACME-1 stopped at In Progress") == true)
    }

    @Test("a pair can move wherever GitHub can, signed in to Jira or not")
    func canMovePair() async throws {
        let (board, _) = await makeBoard(issues: .success([migrated]), items: .success([copy()]))
        let card = try #require(board.card(pair))
        #expect(!board.jira.canMove)
        #expect(board.canMove(card))
    }
}

@Suite("BoardStore search and layout")
@MainActor
struct BoardStoreSearchTests {

    @Test("a query narrows both sources without dropping what was fetched")
    func search() async {
        let (board, _) = await makeBoard()
        board.searchQuery = "widget#2"
        #expect(board.columns.flatMap(\.cards).map(\.reference) == ["widget#2"])
        board.searchQuery = "summary ACME-2"
        #expect(board.columns.flatMap(\.cards).map(\.reference) == ["ACME-2"])
        board.searchQuery = "nothing matches this"
        #expect(board.visibleCount == 0)
        #expect(board.cardCount == 6)
        #expect(board.jira.issues.count == 3)
        board.searchQuery = ""
        #expect(board.visibleCount == 6)
    }

    @Test("the layout is read at launch and written through")
    func layoutPersists() async {
        let preferences = MemoryPreferences()
        preferences.setJiraLayout(.board)
        let (board, _) = await makeBoard(preferences: preferences)
        #expect(board.layout == .board)
        board.layout = .list
        #expect(preferences.jiraLayout() == .list)
    }

    /// Unlike `window`, the layout changes nothing about the query.
    @Test("changing the layout does not refetch")
    func layoutDoesNotRefetch() async {
        let counting = CountingIssues()
        let board = BoardStore(
            jira: JiraStore(issues: counting, links: nil, preferences: MemoryPreferences()),
            projects: ProjectStore(client: nil, preferences: MemoryPreferences()),
            preferences: MemoryPreferences()
        )
        board.layout = .board
        await Task.yield()
        #expect(counting.count == 0)
    }

    @Test("the board is off in the list layout, and while nothing is set up")
    func showsBoard() async {
        let preferences = MemoryPreferences()
        let (listed, _) = await makeBoard(preferences: preferences)
        #expect(!listed.showsBoard)
        listed.layout = .board
        #expect(listed.showsBoard)

        let unconfigured = MemoryPreferences()
        unconfigured.setJiraLayout(.board)
        let (empty, _) = await makeBoard(issues: nil, items: nil, preferences: unconfigured)
        #expect(!empty.isConfigured)
        #expect(!empty.showsBoard)
    }

    @Test("GitHub alone is enough for the board to be set up")
    func githubOnly() async {
        let (board, _) = await makeBoard(issues: nil)
        #expect(board.isConfigured)
        #expect(board.paneState == .content)
    }

    @Test("expanding a card is remembered by its id")
    func expansion() async {
        let (board, _) = await makeBoard()
        board.toggle(.project("a"))
        #expect(board.isExpanded(.project("a")))
        #expect(!board.isExpanded(.jira("ACME-1")))
        board.toggle(.project("a"))
        #expect(!board.isExpanded(.project("a")))
    }
}

@Suite("BoardStore failures and moves")
@MainActor
struct BoardStoreFailureTests {

    @Test("one failing source shows as a banner beside the other's cards")
    func oneSourceFails() async {
        let (board, _) = await makeBoard(issues: .failure(.jiraUnauthorized))
        #expect(board.paneState == .content)
        #expect(board.sourceFailures.count == 1)
        #expect(board.sourceFailures.first?.hasPrefix("Couldn't reach Jira — ") == true)
    }

    /// The scope instruction is the one actionable line; it must not lose to Jira's.
    @Test("when every source failed the pane names each failure, not just the first")
    func everySourceFails() async {
        let (board, _) = await makeBoard(issues: .failure(.jiraUnauthorized), items: .failure(.projectScopeMissing))
        #expect(board.paneState == .failed)
        #expect(board.sourceFailures.isEmpty)
        #expect(board.failureLines.count == 2)
        #expect(board.failureLines.contains { $0.contains("gh auth refresh -s project") })
    }

    /// An empty Jira says nothing about a GitHub board that never answered.
    @Test("an empty board with a failed source fails rather than claiming nothing is assigned")
    func emptyBesideFailure() async {
        let (board, _) = await makeBoard(issues: .success([]), items: .failure(.projectScopeMissing))
        #expect(board.paneState == .failed)
        #expect(board.failureLines == ["Couldn't reach GitHub Projects — "
            + (PRMasterError.projectScopeMissing.errorDescription ?? "")])
    }

    @Test("a GitHub failure names GitHub Projects")
    func githubFails() async {
        let (board, _) = await makeBoard(items: .failure(.projectScopeMissing))
        #expect(board.sourceFailures == ["Couldn't reach GitHub Projects — "
            + (PRMasterError.projectScopeMissing.errorDescription ?? "")])
    }

    @Test("a move goes to the source the card came from")
    func routesMoves() async {
        let jiraMover = OneHopJira()
        let (board, served) = await makeBoard(jiraMover: jiraMover)

        await board.move(.project("a"), to: .reviewing)
        #expect(served?.moved == ["a→o-review"])
        #expect(jiraMover.performed.isEmpty)

        await board.move(.jira("ACME-1"), to: .inProgress)
        #expect(jiraMover.performed == ["ACME-1"])
    }

    @Test("a card id round-trips through a drag, and a foreign string names nothing", arguments: [
        ("jira:ACME-1", BoardCardID.jira("ACME-1")),
        ("project:PVTI_1", BoardCardID.project("PVTI_1")),
        ("project:a:b", BoardCardID.project("a:b")),
        ("paired:ACME-1/PVTI_1", BoardCardID.paired(key: "ACME-1", item: "PVTI_1")),
    ])
    func cardIDs(raw: String, id: BoardCardID) {
        #expect(BoardCardID(rawValue: raw) == id)
        #expect(id.rawValue == raw)
    }

    @Test("strings from other apps are not card ids", arguments: [
        "ACME-1", "jira:", "github:x", "", "https://example.com", "paired:ACME-1", "paired:/PVTI_1", "paired:ACME-1/",
    ])
    func foreign(raw: String) {
        #expect(BoardCardID(rawValue: raw) == nil)
    }

    @Test("a drop names a card only if it is on the board")
    func cardLookup() async {
        let (board, _) = await makeBoard()
        #expect(board.card(.project("a"))?.reference == "widget#1")
        #expect(board.card(.project("e")) == nil)
        #expect(board.card(.jira("ACME-99")) == nil)
    }
}
