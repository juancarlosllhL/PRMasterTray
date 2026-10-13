import Foundation
import Testing
@testable import PRMasterCore

private let now = Date(timeIntervalSince1970: 2_000_000)

func projectItem(
    _ id: String, project: String = "PVT_1", option: String? = "o-todo", name: String? = "Todo",
    number: Int = 1, changedDaysAgo: Double = 1
) -> ProjectItem {
    ProjectItem(
        id: id, projectID: project, number: number, title: "title \(id)",
        url: URL(string: "https://github.com/acme/widget/issues/\(number)")!, repo: "acme/widget",
        isPullRequest: false, typeName: "Task", statusOptionID: option, statusName: name,
        statusChangedAt: now.addingTimeInterval(-changedDaysAgo * 86_400), createdAt: now
    )
}

private final class FakeProjects: ProjectFetching, ProjectItemMoving, @unchecked Sendable {
    private let lock = NSLock()
    private var discovery: Result<[GitHubProject], PRMasterError>
    private var answers: [String: Result<[ProjectItem], PRMasterError>]
    private var asked: [String] = []
    private var moves: [[String]] = []
    private var refusal: PRMasterError?

    init(
        discovery: Result<[GitHubProject], PRMasterError> = .success([]),
        answers: [String: Result<[ProjectItem], PRMasterError>] = [:]
    ) {
        self.discovery = discovery
        self.answers = answers
    }

    var askedFor: [String] { lock.withLock { asked } }
    var moved: [[String]] { lock.withLock { moves } }
    func answer(_ project: String, _ result: Result<[ProjectItem], PRMasterError>) {
        lock.withLock { answers[project] = result }
    }
    func refuseMoves(_ error: PRMasterError) { lock.withLock { refusal = error } }

    func fetchProjects() async throws -> [GitHubProject] { try lock.withLock { discovery }.get() }

    func fetchProjectItems(projectID: String) async throws -> [ProjectItem] {
        try lock.withLock {
            asked.append(projectID)
            return answers[projectID] ?? .success([])
        }.get()
    }

    func setStatus(project: String, item: String, field: String, option: String) async throws {
        try lock.withLock {
            moves.append([project, item, field, option])
            if let refusal { throw refusal }
            if case .success(let items) = answers[project] {
                answers[project] = .success(items.map {
                    $0.id == item ? $0.with(status: StatusOption(id: option, name: ""), at: now) : $0
                })
            }
        }
    }
}

/// Holds the first fetch open until released, to stand in for a poll in flight.
private final class GatedProjects: ProjectFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var gated = true
    private var asked: [String] = []
    var askedFor: [String] { lock.withLock { asked } }

    func fetchProjects() async throws -> [GitHubProject] { [] }

    func fetchProjectItems(projectID: String) async throws -> [ProjectItem] {
        if lock.withLock({ gated }) {
            await withCheckedContinuation { gate in
                lock.withLock {
                    gated = false
                    self.gate = gate
                    entered?.resume()
                    entered = nil
                }
            }
        }
        lock.withLock { asked.append(projectID) }
        return [projectItem("item-\(projectID)", project: projectID)]
    }

    func waitUntilGated() async {
        await withCheckedContinuation { signal in
            lock.withLock { if gate != nil { signal.resume() } else { entered = signal } }
        }
    }

    func release() { lock.withLock { gate?.resume(); gate = nil } }
}

@MainActor
private func makeStore(
    _ fake: FakeProjects, known: [GitHubProject] = [boardProject()],
    selected: [String] = ["PVT_1"], mover: Bool = true
) -> (ProjectStore, MemoryPreferences) {
    let prefs = MemoryPreferences()
    prefs.setKnownProjects(known)
    prefs.setProjectSelection(ProjectSelection(enabled: Set(selected)))
    let store = ProjectStore(
        client: fake, mover: mover ? fake : nil, preferences: prefs,
        now: { now }, sleep: { _ in throw CancellationError() }
    )
    return (store, prefs)
}

@Suite("ProjectStore")
@MainActor
struct ProjectStoreTests {

    @Test("a failed discovery keeps the projects known from last time")
    func discoveryFailureKeepsKnown() async {
        let (store, _) = makeStore(FakeProjects(discovery: .failure(.projectScopeMissing)))
        await store.discover()
        #expect(store.projects.map(\.id) == ["PVT_1"])
        #expect(store.discoveryError == .projectScopeMissing)
    }

    /// Recent projects rotate out of GitHub's answer; a board you chose must not go with them.
    @Test("discovery replaces the list but keeps a selected board it no longer found")
    func discoveryKeepsSelected() async {
        let fake = FakeProjects(discovery: .success([boardProject("PVT_2", title: "New board")]))
        let (store, prefs) = makeStore(fake, known: [boardProject(), boardProject("PVT_3")])
        await store.discover()
        #expect(Set(store.projects.map(\.id)) == ["PVT_1", "PVT_2"])
        #expect(Set(prefs.knownProjects().map(\.id)) == ["PVT_1", "PVT_2"])
        #expect(store.discoveryError == nil)
    }

    @Test("a refresh asks only for selected boards that have a Status field")
    func refreshAsksSelected() async {
        let fake = FakeProjects()
        let (store, _) = makeStore(
            fake,
            known: [boardProject(), boardProject("PVT_2"), boardProject("PVT_3", statusFieldID: nil, options: [])],
            selected: ["PVT_1", "PVT_3"]
        )
        await store.refresh()
        #expect(fake.askedFor == ["PVT_1"])
    }

    @Test("a board that fails keeps its last items while the others update")
    func partialFailure() async {
        let fake = FakeProjects(answers: [
            "PVT_1": .success([projectItem("a")]),
            "PVT_2": .success([projectItem("b", project: "PVT_2")]),
        ])
        let (store, _) = makeStore(fake, known: [boardProject(), boardProject("PVT_2")], selected: ["PVT_1", "PVT_2"])
        await store.refresh()

        fake.answer("PVT_1", .failure(.httpError(status: 502)))
        fake.answer("PVT_2", .success([projectItem("c", project: "PVT_2")]))
        await store.refresh()

        #expect(Set(store.items.map(\.id)) == ["a", "c"])
        #expect(store.lastError == .httpError(status: 502))
        #expect(store.lastSuccessfulFetch == now)
    }

    @Test("switching a board on persists and fetches it")
    func selectionPersistsAndRefetches() async {
        let fake = FakeProjects(answers: ["PVT_2": .success([projectItem("b", project: "PVT_2")])])
        let (store, prefs) = makeStore(fake, known: [boardProject(), boardProject("PVT_2")])
        store.setShown(boardProject("PVT_2"), true)
        await store.pendingRefresh?.value
        #expect(prefs.projectSelection().enabled == ["PVT_1", "PVT_2"])
        #expect(fake.askedFor.contains("PVT_2"))
        #expect(store.items.map(\.id) == ["b"])
    }

    /// Otherwise the new board waits for the next poll, up to five minutes away.
    @Test("a board switched on while a refresh is in flight is fetched when it lands")
    func selectionDuringRefresh() async {
        let gated = GatedProjects()
        let prefs = MemoryPreferences()
        prefs.setKnownProjects([boardProject(), boardProject("PVT_2")])
        prefs.setProjectSelection(ProjectSelection(enabled: ["PVT_1"]))
        let store = ProjectStore(client: gated, preferences: prefs, now: { now }, sleep: { _ in throw CancellationError() })

        let inFlight = Task { await store.refresh() }
        await gated.waitUntilGated()
        await store.refresh()
        store.setShown(boardProject("PVT_2"), true)
        gated.release()
        await inFlight.value
        await store.pendingRefresh?.value

        #expect(gated.askedFor.contains("PVT_2"))
        #expect(Set(store.items.map(\.projectID)) == ["PVT_1", "PVT_2"])
    }

    @Test("switching every board off empties the GitHub half")
    func selectionEmptied() async {
        let fake = FakeProjects(answers: ["PVT_1": .success([projectItem("a")])])
        let (store, _) = makeStore(fake)
        await store.refresh()
        store.setShown(boardProject(), false)
        #expect(store.items.isEmpty)
        #expect(!store.isConfigured)
    }

    @Test("changing the column map persists without asking GitHub again")
    func mapPersistsOnly() async {
        let fake = FakeProjects()
        let (store, prefs) = makeStore(fake)
        store.setChoice(.hidden, option: "o-qa", in: boardProject())
        #expect(prefs.projectLaneMap().overrides["PVT_1"]?["o-qa"] == .hidden)
        #expect(store.pendingRefresh == nil)
        #expect(fake.askedFor.isEmpty)
    }

    @Test("an item's lane follows the column map")
    func laneFollowsMap() async {
        let fake = FakeProjects(answers: ["PVT_1": .success([projectItem("a", option: "o-qa", name: "QA")])])
        let (store, _) = makeStore(fake)
        await store.refresh()
        let item = store.items[0]
        #expect(store.lane(of: item) == .testing)
        store.setChoice(.reviewing, option: "o-qa", in: boardProject())
        #expect(store.lane(of: item) == .reviewing)
    }

    @Test("a move sets the Status option mapped to the target column")
    func moves() async {
        let fake = FakeProjects(answers: ["PVT_1": .success([projectItem("a")])])
        let (store, _) = makeStore(fake)
        await store.refresh()
        await store.move("a", to: .reviewing)
        #expect(fake.moved == [["PVT_1", "a", "PVTSSF_1", "o-review"]])
        #expect(store.lane(of: store.items[0]) == .reviewing)
        #expect(store.lastMoveFailure == nil)
    }

    @Test("a column no option maps to refuses the move and says where to fix it")
    func noTarget() async {
        let project = boardProject(options: [("o-todo", "Todo"), ("o-done", "Done")])
        let fake = FakeProjects(answers: ["PVT_1": .success([projectItem("a")])])
        let (store, _) = makeStore(fake, known: [project])
        await store.refresh()
        await store.move("a", to: .testing)
        #expect(fake.moved.isEmpty)
        #expect(store.lastMoveFailure == "Platform Board has no Status option in Testing. Map one under Settings, Board.")
    }

    @Test("a refused move puts the card back and says why")
    func refused() async {
        let fake = FakeProjects(answers: ["PVT_1": .success([projectItem("a")])])
        fake.refuseMoves(.graphQL(["Resource not accessible"]))
        let (store, _) = makeStore(fake)
        await store.refresh()
        await store.move("a", to: .done)
        #expect(store.lane(of: store.items[0]) == .toDo)
        #expect(!store.isMoving("a"))
        #expect(store.lastMoveFailure == "Couldn't move widget#1 — Resource not accessible")
    }

    @Test("with no mover nothing can be moved")
    func noMover() async {
        let fake = FakeProjects(answers: ["PVT_1": .success([projectItem("a")])])
        let (store, _) = makeStore(fake, mover: false)
        await store.refresh()
        #expect(!store.canMove)
        await store.move("a", to: .done)
        #expect(fake.moved.isEmpty)
    }
}
