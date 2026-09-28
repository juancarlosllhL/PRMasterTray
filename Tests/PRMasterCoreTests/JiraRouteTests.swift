import Foundation
import Testing
@testable import PRMasterCore

private func status(_ name: String, _ category: JiraStatusCategory) -> JiraStatus {
    JiraStatus(name: name, category: category)
}

private func transition(
    _ id: String, _ name: String, _ category: JiraStatusCategory,
    global: Bool = false, needsInput: Bool = false
) -> JiraTransition {
    JiraTransition(id: id, to: status(name, category), isGlobal: global, needsInput: needsInput)
}

/// Offered from every ACME status, in the order Jira lists them.
private let globals = [
    transition("2", "Customer Validation", .toDo, global: true),
    transition("3", "Awaiting Customer", .toDo, global: true),
    transition("11", "On Hold", .toDo, global: true),
    transition("21", "Canceled", .done, global: true, needsInput: true),
]

private let inProgress = status("In Progress", .inProgress)
private let reviewing = status("Reviewing", .inProgress)
private let testing = status("Testing", .inProgress)

private let taskFromInProgress = globals + [
    transition("31", "To Do", .toDo),
    transition("41", "New", .toDo),
    transition("61", "Reviewing", .inProgress),
]
private let taskFromReviewing = globals + [
    transition("51", "In Progress", .inProgress),
    transition("71", "Testing", .inProgress),
]
private let bugFromTesting = globals + [
    transition("41", "New", .toDo),
    transition("61", "Reviewing", .inProgress),
    transition("81", "Done", .done),
    transition("91", "External Testing", .done),
]

@Suite("JiraRoute")
struct JiraRouteTests {

    private func hop(
        _ current: JiraStatus, _ target: JiraLane, _ offered: [JiraTransition],
        visited: Set<String> = []
    ) -> String? {
        JiraRoute.nextHop(
            from: current, toward: target, offered: offered,
            visited: visited.union([current.name])
        )?.id
    }

    /// ACME has no edge from In Progress to Testing. Reviewing is the only way.
    @Test("In Progress reaches Testing through Reviewing")
    func throughReviewing() {
        #expect(hop(inProgress, .testing, taskFromInProgress) == "61")
        #expect(hop(reviewing, .testing, taskFromReviewing, visited: ["In Progress"]) == "71")
    }

    @Test("In Progress reaches the Reviewing column in one hop, and back")
    func intoAndOutOfReviewing() {
        #expect(hop(inProgress, .reviewing, taskFromInProgress) == "61")
        #expect(hop(reviewing, .inProgress, taskFromReviewing) == "51")
        #expect(hop(testing, .reviewing, bugFromTesting) == "61")
    }

    /// External Testing is category done on Bugs, so it would satisfy the lane.
    @Test("a move to Done takes the status named Done")
    func prefersTheNamedStatus() {
        #expect(hop(testing, .done, bugFromTesting) == "81")
    }

    @Test("Canceled is never taken, even when it is the only way into Done")
    func neverCancels() {
        #expect(hop(testing, .done, globals) == nil)
    }

    /// Some sites ask for no resolution on Cancel, so `needsInput` alone cannot keep it out.
    @Test("a global transition that needs no input still never cancels")
    func neverCancelsWithoutInput() {
        let offered = [transition("21", "Canceled", .done, global: true)]
        #expect(hop(testing, .done, offered) == nil)
    }

    /// Simplified workflows make every transition global.
    @Test("a global transition to the status named like the lane is taken")
    func simplifiedWorkflow() {
        let offered = [
            transition("21", "Canceled", .done, global: true),
            transition("31", "Done", .done, global: true),
        ]
        #expect(hop(testing, .done, offered) == "31")
    }

    @Test("a closer parked status loses to a real step toward the target")
    func parkedNeverRoutes() {
        let offered = [
            transition("11", "On Hold", .toDo),
            transition("41", "New", .toDo),
        ]
        #expect(hop(inProgress, .toDo, offered) == "41")
        #expect(hop(status("New", .toDo), .inProgress, [transition("11", "On Hold", .toDo)]) == nil)
    }

    @Test("between two equally good hops, Jira's own order wins")
    func tieKeepsJiraOrder() {
        let offered = [
            transition("61", "Reviewing", .inProgress),
            transition("62", "Code Review", .inProgress),
        ]
        #expect(hop(inProgress, .testing, offered) == "61")
        #expect(hop(inProgress, .testing, offered.reversed()) == "62")
    }

    @Test("a lane reachable both ways is entered by the workflow's own edge")
    func prefersNonGlobal() {
        let offered = [
            transition("5", "Shipped", .done, global: true),
            transition("6", "Released", .done),
        ]
        #expect(hop(testing, .done, offered) == "6")
    }

    @Test("a move to To do takes To Do over New")
    func prefersToDoOverNew() {
        #expect(hop(inProgress, .toDo, taskFromInProgress.reversed()) == "31")
    }

    @Test("a status already visited is never re-entered, so a dead end gives nil")
    func deadEnd() {
        let offered = globals + [transition("51", "In Progress", .inProgress)]
        #expect(hop(reviewing, .testing, offered, visited: ["In Progress"]) == nil)
    }

    @Test("a hop that only moves away from the target is never taken")
    func neverBackwards() {
        let offered = globals + [transition("31", "To Do", .toDo)]
        #expect(hop(inProgress, .done, offered) == nil)
    }

    @Test("the hop closest to the target wins over a sideways one")
    func closestWins() {
        let offered = [
            transition("41", "New", .toDo),
            transition("51", "In Progress", .inProgress),
        ]
        #expect(hop(status("To Do", .toDo), .done, offered) == "51")
    }

    @Test("a parked issue is not routed at all")
    func parkedIsNotRouted() {
        #expect(hop(status("On Hold", .toDo), .inProgress, taskFromReviewing) == nil)
    }
}
