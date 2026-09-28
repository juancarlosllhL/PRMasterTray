import Foundation
import Testing
@testable import PRMasterCore

private func status(_ name: String) -> JiraStatus {
    switch name {
    case "To Do", "New", "On Hold": return JiraStatus(name: name, category: .toDo)
    case "Done", "Canceled":        return JiraStatus(name: name, category: .done)
    default:                        return JiraStatus(name: name, category: .inProgress)
    }
}

/// A workflow keyed by status name: each entry lists `(transition id, destination)`.
private typealias Workflow = [String: [(String, String)]]

/// The ACME Task workflow as read from the live site, globals included.
private let acmeTask: Workflow = {
    let globals = [("11", "On Hold"), ("21", "Canceled")]
    return [
        "To Do": globals + [("41", "New"), ("51", "In Progress")],
        "New": globals + [("31", "To Do"), ("51", "In Progress"), ("71", "Testing")],
        "In Progress": globals + [("31", "To Do"), ("41", "New"), ("61", "Reviewing")],
        "Reviewing": globals + [("51", "In Progress"), ("71", "Testing")],
        "Testing": globals + [("81", "Done"), ("41", "New"), ("61", "Reviewing")],
        "Done": globals + [("71", "Testing")],
    ]
}()

/// Plays a workflow the way Jira does: moves only along offered edges.
private final class WorkflowClient: JiraIssueMoving, @unchecked Sendable {
    private let lock = NSLock()
    private let workflow: Workflow
    private var current: String
    private let failPost: PRMasterError?
    private let failAfter: Int
    private let screens: [String: [JiraField]]
    private(set) var posted: [String] = []
    private(set) var values: [[String: String]] = []

    init(
        _ workflow: Workflow, at start: String, failPost: PRMasterError? = nil, after: Int = 0,
        screens: [String: [JiraField]] = [:]
    ) {
        self.workflow = workflow
        self.current = start
        self.failPost = failPost
        self.failAfter = after
        self.screens = screens
    }

    func transitions(for key: String) async throws -> (JiraStatus, [JiraTransition]) {
        lock.withLock {
            let offered = (workflow[current] ?? []).map { id, to in
                JiraTransition(
                    id: id, to: status(to),
                    isGlobal: id == "11" || id == "21", needsInput: to == "Canceled",
                    fields: current == "Reviewing" ? screens[id] ?? [] : []
                )
            }
            return (status(current), offered)
        }
    }

    func perform(_ transition: JiraTransition, on key: String, values: [String: String]) async throws {
        let transitionID = transition.id
        if let failPost, lock.withLock({ posted.count >= failAfter }) { throw failPost }
        lock.withLock {
            posted.append(transitionID)
            self.values.append(values)
            if let edge = workflow[current]?.first(where: { $0.0 == transitionID }) {
                current = edge.1
            }
        }
    }
}

/// Answers every form with the same values, and remembers what it was asked.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private let answer: [String: String]?
    private(set) var requests: [JiraFieldRequest] = []

    init(answer: [String: String]?) { self.answer = answer }

    var ask: @Sendable (JiraFieldRequest) async -> [String: String]? {
        { request in
            self.lock.withLock {
                self.requests.append(request)
                return self.answer
            }
        }
    }
}

@Suite("JiraMove")
struct JiraMoveTests {

    @Test("In Progress reaches Testing by way of Reviewing")
    func inProgressToTesting() async {
        let client = WorkflowClient(acmeTask, at: "In Progress")
        let outcome = await JiraMove(client: client).run("ACME-1", to: .testing)
        #expect(outcome == .moved(to: status("Testing")))
        #expect(client.posted == ["61", "71"])
    }

    @Test("To Do reaches Done in four hops")
    func toDoToDone() async {
        let client = WorkflowClient(acmeTask, at: "To Do")
        let outcome = await JiraMove(client: client).run("ACME-1", to: .done)
        #expect(outcome == .moved(to: status("Done")))
        #expect(client.posted == ["51", "61", "71", "81"])
    }

    @Test("Done goes back to To do through Testing and New")
    func backwards() async {
        let client = WorkflowClient(acmeTask, at: "Done")
        let outcome = await JiraMove(client: client).run("ACME-1", to: .toDo)
        #expect(outcome == .moved(to: status("New")))
        #expect(client.posted == ["71", "41"])
    }

    @Test("To Do reaches Reviewing through In Progress")
    func toDoToReviewing() async {
        let client = WorkflowClient(acmeTask, at: "To Do")
        let outcome = await JiraMove(client: client).run("ACME-1", to: .reviewing)
        #expect(outcome == .moved(to: status("Reviewing")))
        #expect(client.posted == ["51", "61"])
    }

    @Test("an issue already in the lane is left alone")
    func alreadyThere() async {
        let client = WorkflowClient(acmeTask, at: "Reviewing")
        let outcome = await JiraMove(client: client).run("ACME-1", to: .reviewing)
        #expect(outcome == .moved(to: status("Reviewing")))
        #expect(client.posted.isEmpty)
    }

    @Test("a dead end reports the status the issue was left in")
    func deadEnd() async {
        let broken: Workflow = [
            "In Progress": [("61", "Reviewing")],
            "Reviewing": [("51", "In Progress")],
        ]
        let client = WorkflowClient(broken, at: "In Progress")
        let outcome = await JiraMove(client: client).run("ACME-1", to: .testing)
        #expect(outcome == .stopped(at: status("Reviewing"), target: .testing))
        #expect(client.posted == ["61"])
    }

    @Test("a refused hop reports Jira's reason")
    func refused() async {
        let client = WorkflowClient(
            acmeTask, at: "In Progress", failPost: .jiraMoveRefused("No permission.")
        )
        let outcome = await JiraMove(client: client).run("ACME-1", to: .testing)
        #expect(outcome == .failed("No permission.", leftAt: nil))
    }

    @Test("a hop refused after others went through says where the issue was left")
    func refusedPartway() async {
        let client = WorkflowClient(
            acmeTask, at: "In Progress", failPost: .jiraMoveRefused("No permission."), after: 1
        )
        let outcome = await JiraMove(client: client).run("ACME-1", to: .testing)
        #expect(outcome == .failed("No permission.", leftAt: status("Reviewing")))
        #expect(client.posted == ["61"])
    }

    @Test("a hop with a screen asks for its fields and posts the answer")
    func asksForScreenFields() async {
        let remark = JiraField(id: "customfield_10170", name: "Remark", kind: .richText)
        let client = WorkflowClient(acmeTask, at: "In Progress", screens: ["71": [remark]])
        let asked = Asked(answer: ["customfield_10170": "PM: done"])

        let outcome = await JiraMove(client: client, askFor: asked.ask).run("ACME-1", to: .testing)

        #expect(outcome == .moved(to: status("Testing")))
        #expect(client.posted == ["61", "71"])
        #expect(client.values == [[:], ["customfield_10170": "PM: done"]])
        #expect(asked.requests == [JiraFieldRequest(
            key: "ACME-1", from: status("Reviewing"), to: status("Testing"), fields: [remark]
        )])
    }

    @Test("closing the form stops the walk where it stands, without posting that hop")
    func cancelledForm() async {
        let remark = JiraField(id: "customfield_10170", name: "Remark", kind: .richText)
        let client = WorkflowClient(acmeTask, at: "In Progress", screens: ["71": [remark]])
        let asked = Asked(answer: nil)

        let outcome = await JiraMove(client: client, askFor: asked.ask).run("ACME-1", to: .testing)

        #expect(outcome == .cancelled(leftAt: status("Reviewing")))
        #expect(client.posted == ["61"])
    }

    @Test("a workflow that never arrives is abandoned after six hops")
    func hopCap() async {
        let endless: Workflow = Dictionary(uniqueKeysWithValues: (0..<20).map {
            ("Step \($0)", [("\($0 + 1)", "Step \($0 + 1)")])
        })
        let client = WorkflowClient(endless, at: "Step 0")
        let outcome = await JiraMove(client: client).run("ACME-1", to: .testing)
        #expect(outcome == .stopped(at: status("Step 6"), target: .testing))
        #expect(client.posted.count == JiraMove.maxHops)
    }
}
