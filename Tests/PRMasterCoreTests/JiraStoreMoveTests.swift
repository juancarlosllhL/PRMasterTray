import Foundation
import Testing
@testable import PRMasterCore

private let now = Date(timeIntervalSince1970: 1_000_000)

private func issue(_ key: String, _ status: String, _ category: JiraStatusCategory) -> JiraIssue {
    JiraIssue(
        key: key, summary: "summary", statusName: status, statusCategory: category,
        issueType: "Task", updatedAt: now,
        categoryChangedAt: category == .done ? now : nil
    )
}

private let toDo = issue("ACME-1", "To Do", .toDo)
private let inProgress = issue("ACME-1", "In Progress", .inProgress)

/// Answers each fetch from a script. A gated fetch holds until released.
private final class ScriptedIssues: JiraIssueFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<[JiraIssue], PRMasterError>]
    private var gate: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var gatesNext = false

    init(_ answers: [Result<[JiraIssue], PRMasterError>]) { self.answers = answers }

    func gateNextFetch() { lock.withLock { gatesNext = true } }

    func fetchAssignedIssues(within window: JiraWindow) async throws -> [JiraIssue] {
        if lock.withLock({ gatesNext }) {
            await withCheckedContinuation { gate in
                lock.withLock {
                    gatesNext = false
                    self.gate = gate
                    entered?.resume()
                    entered = nil
                }
            }
        }
        let next = lock.withLock { answers.isEmpty ? .success([]) : answers.removeFirst() }
        return try next.get()
    }

    func waitUntilGated() async {
        await withCheckedContinuation { signal in
            lock.withLock { if gate != nil { signal.resume() } else { entered = signal } }
        }
    }

    func release() { lock.withLock { gate?.resume(); gate = nil } }
}

/// ACME's path from To Do to Testing, whose POST can be held open or refused after some hops.
private final class Mover: JiraIssueMoving, @unchecked Sendable {
    private static let statuses = [
        "51": JiraStatus(name: "In Progress", category: .inProgress),
        "61": JiraStatus(name: "Reviewing", category: .inProgress),
        "71": JiraStatus(name: "Testing", category: .inProgress),
        "81": JiraStatus(name: "Done", category: .done),
    ]
    private static let edges = [
        "To Do": ["51", "81"],
        "In Progress": ["61"],
        "Reviewing": ["71"],
    ]

    private let lock = NSLock()
    private var current: JiraStatus
    private let failure: PRMasterError?
    private let failAfter: Int
    private let routes: Bool
    private let screens: [String: [JiraField]]
    private(set) var values: [[String: String]] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private let gated: Bool
    private(set) var posted: [String] = []
    private(set) var reads = 0

    init(
        gated: Bool = false, failure: PRMasterError? = nil, failAfter: Int = 0,
        routes: Bool = true, start: String = "To Do", screens: [String: [JiraField]] = [:]
    ) {
        self.screens = screens
        self.gated = gated
        self.failure = failure
        self.failAfter = failAfter
        self.routes = routes
        self.current = start == "To Do"
            ? JiraStatus(name: start, category: .toDo)
            : JiraStatus(name: start, category: .inProgress)
    }

    func transitions(for key: String) async throws -> (JiraStatus, [JiraTransition]) {
        lock.withLock {
            reads += 1
            guard routes else { return (current, []) }
            let offered = (Self.edges[current.name] ?? []).map { id in
                JiraTransition(
                    id: id, to: Self.statuses[id]!, isGlobal: false, needsInput: false,
                    fields: screens[id] ?? []
                )
            }
            return (current, offered)
        }
    }

    func perform(_ transition: JiraTransition, on key: String, values: [String: String]) async throws {
        let transitionID = transition.id
        if gated {
            await withCheckedContinuation { gate in
                lock.withLock { self.gate = gate; entered?.resume(); entered = nil }
            }
        }
        if let failure, lock.withLock({ posted.count >= failAfter }) { throw failure }
        lock.withLock {
            posted.append(transitionID)
            self.values.append(values)
            current = Self.statuses[transitionID]!
        }
    }

    func waitUntilPosting() async {
        await withCheckedContinuation { signal in
            lock.withLock { if gate != nil { signal.resume() } else { entered = signal } }
        }
    }

    func release() { lock.withLock { gate?.resume(); gate = nil } }
}

@MainActor
private func store(
    _ answers: [Result<[JiraIssue], PRMasterError>], mover: Mover?
) async -> (JiraStore, ScriptedIssues) {
    let issues = ScriptedIssues(answers)
    let store = JiraStore(
        issues: issues, links: nil, mover: mover,
        preferences: MemoryPreferences(), now: { now }, sleep: { _ in }
    )
    await store.refresh()
    return (store, issues)
}

private let remark = JiraField(id: "customfield_10170", name: "Remark", kind: .richText)
private let started = JiraIssue(
    key: "ACME-1", summary: "s", statusName: "In Progress", statusCategory: .inProgress,
    issueType: "Task", updatedAt: now
)

/// The form opens after the first hop's round trip, so yield until it is up.
@MainActor
private func formOpens(on store: JiraStore) async {
    for _ in 0..<10_000 where store.fieldRequest == nil { await Task.yield() }
}

private let offline = Result<[JiraIssue], PRMasterError>.failure(.httpError(status: 503))

@Suite("JiraStore moves")
@MainActor
struct JiraStoreMoveTests {

    @Test("a card sits in its target column while Jira is still moving it")
    func landsAtOnce() async {
        let mover = Mover(gated: true)
        let (store, _) = await store([.success([toDo]), .success([inProgress])], mover: mover)

        let move = Task { await store.move("ACME-1", to: .inProgress) }
        await mover.waitUntilPosting()

        #expect(store.visibleGroups.inProgress.map(\.key) == ["ACME-1"])
        #expect(store.visibleGroups.toDo.isEmpty)
        #expect(store.isMoving("ACME-1"))

        mover.release()
        await move.value

        #expect(!store.isMoving("ACME-1"))
        #expect(store.visibleGroups.inProgress.map(\.key) == ["ACME-1"])
        #expect(mover.posted == ["51"])
        #expect(store.lastMoveFailure == nil)
        #expect(store.moves.isEmpty, "the refresh after a settled move clears its override")
    }

    @Test("a confirmed move keeps the card in place even if the next fetch fails")
    func patchedOnSuccess() async {
        let (store, _) = await store([.success([toDo]), offline], mover: Mover())

        await store.move("ACME-1", to: .inProgress)

        #expect(store.issues.first?.statusName == "In Progress")
        #expect(store.visibleGroups.inProgress.map(\.key) == ["ACME-1"])
    }

    @Test("a refused move puts the card back and says why")
    func refusedGoesBack() async {
        let mover = Mover(failure: .jiraMoveRefused("No permission."))
        let (store, _) = await store([.success([toDo]), .success([toDo])], mover: mover)

        await store.move("ACME-1", to: .inProgress)

        #expect(store.visibleGroups.toDo.map(\.key) == ["ACME-1"])
        #expect(store.lastMoveFailure?.contains("ACME-1") == true)
        #expect(store.lastMoveFailure?.contains("No permission.") == true)
    }

    @Test("a move refused partway names the status Jira left the issue in")
    func refusedPartwayNamesStatus() async {
        let mover = Mover(failure: .jiraMoveRefused("No permission."), failAfter: 1, start: "In Progress")
        let (store, _) = await store([.success([toDo]), .success([toDo])], mover: mover)

        await store.move("ACME-1", to: .testing)

        #expect(store.lastMoveFailure?.contains("Reviewing") == true)
        #expect(store.lastMoveFailure?.contains("No permission.") == true)
    }

    /// Reviewing is still In progress, so the card never left that category.
    @Test("a move within one category keeps when the category last changed")
    func sameCategoryKeepsTimestamp() async {
        let changed = Date(timeIntervalSince1970: 500_000)
        let started = JiraIssue(
            key: "ACME-1", summary: "s", statusName: "In Progress", statusCategory: .inProgress,
            issueType: "Task", updatedAt: now, categoryChangedAt: changed
        )
        let (store, _) = await store([.success([started]), offline], mover: Mover(start: "In Progress"))

        await store.move("ACME-1", to: .testing)

        #expect(store.issues.first?.statusName == "Testing")
        #expect(store.issues.first?.categoryChangedAt == changed)
    }

    @Test("a move with no route puts the card back and names where it stopped")
    func deadEndGoesBack() async {
        let (store, _) = await store([.success([toDo]), .success([toDo])], mover: Mover(routes: false))

        await store.move("ACME-1", to: .testing)

        #expect(store.visibleGroups.toDo.map(\.key) == ["ACME-1"])
        #expect(store.lastMoveFailure?.contains("To Do") == true)
        #expect(store.lastMoveFailure?.contains("Testing") == true)
    }

    /// The poll was already reading Jira before the move landed, so its answer
    /// is older than the move and must not snap the card back.
    @Test("a fetch that started before the move settled leaves the card in place")
    func staleFetchKeepsOverride() async {
        let (store, issues) = await store(
            [.success([toDo]), .success([toDo]), .success([inProgress])], mover: Mover()
        )

        issues.gateNextFetch()
        let poll = Task { await store.refresh() }
        await issues.waitUntilGated()

        await store.move("ACME-1", to: .inProgress)
        issues.release()
        await poll.value

        #expect(store.visibleGroups.inProgress.map(\.key) == ["ACME-1"])

        await store.refresh()
        #expect(store.visibleGroups.inProgress.map(\.key) == ["ACME-1"])
        #expect(store.moves.isEmpty)
    }

    @Test("moves that cannot apply make no request", arguments: ["unknown", "same lane", "no mover"])
    func noOps(case name: String) async {
        let mover = Mover()
        let (store, _) = await store([.success([toDo])], mover: name == "no mover" ? nil : mover)

        switch name {
        case "unknown":   await store.move("ACME-999", to: .inProgress)
        case "same lane": await store.move("ACME-1", to: .toDo)
        default:          await store.move("ACME-1", to: .inProgress)
        }

        #expect(mover.reads == 0)
        #expect(store.moves.isEmpty)
        #expect(store.canMove == (name != "no mover"))
    }

    @Test("a second move of a card already moving is ignored")
    func noDoubleMove() async {
        let mover = Mover(gated: true)
        let (store, _) = await store([.success([toDo]), .success([inProgress])], mover: mover)

        let first = Task { await store.move("ACME-1", to: .inProgress) }
        await mover.waitUntilPosting()
        await store.move("ACME-1", to: .done)
        mover.release()
        await first.value

        #expect(mover.posted == ["51"])
        #expect(mover.reads == 2, "one read to route, one to confirm arrival, none for the second move")
    }

    /// Done only shows what finished inside the window, so a card finished a
    /// moment ago must count as finished now, not whenever it last changed.
    @Test("a card moved to Done stays inside the Done window")
    func doneStaysInWindow() async {
        let (store, _) = await store([.success([toDo]), offline], mover: Mover())

        await store.move("ACME-1", to: .done)

        #expect(store.visibleGroups.done.map(\.key) == ["ACME-1"])
        #expect(store.issues.first?.categoryChangedAt == now)
    }

    @Test("dismissing the failure banner clears it and nothing else")
    func dismiss() async {
        let mover = Mover(failure: .jiraMoveRefused("No."))
        let (store, _) = await store([.success([toDo]), .success([toDo])], mover: mover)
        await store.move("ACME-1", to: .inProgress)
        #expect(store.lastMoveFailure != nil)

        store.dismissMoveFailure()

        #expect(store.lastMoveFailure == nil)
        #expect(store.canMove)
        #expect(store.visibleGroups.toDo.map(\.key) == ["ACME-1"])
    }

    @Test("a step with a screen opens a form, and only a valid answer is sent")
    func formGatesTheHop() async {
        let mover = Mover(start: "In Progress", screens: ["71": [remark]])
        let (store, _) = await store([.success([started]), .success([started])], mover: mover)

        let move = Task { await store.move("ACME-1", to: .testing) }
        await formOpens(on: store)

        #expect(store.fieldRequest?.to.name == "Testing")
        #expect(store.isMoving("ACME-1"))

        store.submitFields(["customfield_10170": "  "])
        #expect(store.fieldRequest != nil, "an empty Remark is refused and the form stays")

        store.submitFields(["customfield_10170": "Fixed it."])
        await move.value

        #expect(store.fieldRequest == nil)
        #expect(mover.posted == ["61", "71"])
        #expect(mover.values.last == ["customfield_10170": "PM: Fixed it."])
        #expect(store.lastMoveFailure == nil)
    }

    @Test("cancelling the form puts the card back and says where Jira left it")
    func cancelledForm() async {
        let mover = Mover(start: "In Progress", screens: ["71": [remark]])
        let (store, _) = await store([.success([started]), .success([started])], mover: mover)

        let move = Task { await store.move("ACME-1", to: .testing) }
        await formOpens(on: store)
        store.cancelFields()
        await move.value

        #expect(store.fieldRequest == nil)
        #expect(mover.posted == ["61"])
        #expect(store.moves.isEmpty)
        #expect(store.lastMoveFailure?.contains("Reviewing") == true)
    }

    @Test("a second form waits for nobody: it is refused while one is open")
    func oneFormAtATime() async {
        let other = JiraIssue(
            key: "ACME-2", summary: "s", statusName: "In Progress", statusCategory: .inProgress,
            issueType: "Task", updatedAt: now
        )
        let mover = Mover(start: "In Progress", screens: ["71": [remark]])
        let (store, _) = await store([.success([started, other]), .success([started, other])], mover: mover)

        let first = Task { await store.move("ACME-1", to: .testing) }
        await formOpens(on: store)
        await store.move("ACME-2", to: .testing)

        #expect(store.fieldRequest?.key == "ACME-1")
        #expect(store.lastMoveFailure?.contains("ACME-1") == true)

        store.cancelFields()
        await first.value
    }

    @Test("signing out closes an open form and releases its move")
    func signOutClosesForm() async {
        let mover = Mover(start: "In Progress", screens: ["71": [remark]])
        let (store, _) = await store([.success([started])], mover: mover)

        let move = Task { await store.move("ACME-1", to: .testing) }
        await formOpens(on: store)
        store.connect(nil)
        await move.value

        #expect(store.fieldRequest == nil)
        #expect(mover.posted == ["61"])
        #expect(store.lastMoveFailure == nil, "a move from the old session reports nothing")
        #expect(store.moves.isEmpty)
    }

    @Test("signing out forgets moves and their failures")
    func connectClears() async {
        let mover = Mover(failure: .jiraMoveRefused("No."))
        let (store, _) = await store([.success([toDo]), .success([toDo])], mover: mover)
        await store.move("ACME-1", to: .inProgress)

        store.connect(nil)

        #expect(store.lastMoveFailure == nil)
        #expect(store.moves.isEmpty)
        #expect(!store.canMove)
    }
}
