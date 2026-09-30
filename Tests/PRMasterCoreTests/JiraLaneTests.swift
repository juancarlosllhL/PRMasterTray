import Foundation
import Testing
@testable import PRMasterCore

@Suite("JiraLane")
struct JiraLaneTests {

    /// Statuses and categories exactly as the ACME workflow reports them.
    static let acme: [(String, JiraStatusCategory, JiraLane?)] = [
        ("To Do", .toDo, .toDo),
        ("New", .toDo, .toDo),
        ("On Hold", .toDo, nil),
        ("Awaiting Customer", .toDo, nil),
        ("Customer Validation", .toDo, nil),
        ("In Progress", .inProgress, .inProgress),
        ("Reviewing", .inProgress, .reviewing),
        ("Code Review", .inProgress, .reviewing),
        ("Testing", .inProgress, .testing),
        ("Done", .done, .done),
        ("External Testing", .done, .done),
        ("Canceled", .done, .done),
        ("Whatever", .unknown, .inProgress),
    ]

    @Test("each ACME status lands in the lane its column shows it in", arguments: acme)
    func lanes(name: String, category: JiraStatusCategory, expected: JiraLane?) {
        #expect(JiraGrouping.lane(statusName: name, category: category) == expected)
    }

    /// Jira names statuses in each user's profile language: a Spanish account reads "Pruebas".
    static let translated: [(String, String, JiraStatusCategory, JiraLane?)] = [
        ("10000", "Tareas por hacer", .toDo, .toDo),
        ("10029", "Nueva", .toDo, .toDo),
        ("10032", "En espera", .toDo, nil),
        ("3", "En curso", .inProgress, .inProgress),
        ("1", "En revisión", .inProgress, .reviewing),
        ("6", "Pruebas", .inProgress, .testing),
        ("10001", "Hecho", .done, .done),
    ]

    @Test("an ACME status keeps its lane whatever language names it", arguments: translated)
    func translatedLanes(id: String, name: String, category: JiraStatusCategory, expected: JiraLane?) {
        #expect(JiraGrouping.lane(statusName: name, category: category, statusID: id) == expected)
    }

    @Test("a status outside the ACME table still goes by its name")
    func unknownIDGoesByName() {
        #expect(JiraGrouping.lane(statusName: "QA Testing", category: .inProgress, statusID: "99999") == .testing)
        #expect(JiraGrouping.lane(statusName: "Pruebas", category: .inProgress, statusID: nil) == .inProgress)
    }

    @Test("a Spanish account's issue in Testing is grouped under Testing")
    func translatedIssueGroups() {
        let issue = JiraIssue(
            key: "ACME-63335", summary: "s", statusName: "Pruebas", statusID: "6",
            statusCategory: .inProgress, issueType: "Story", updatedAt: .distantPast
        )
        let groups = JiraGrouping.group([issue], window: .default, now: .distantPast)
        #expect(groups.testing.map(\.key) == ["ACME-63335"])
        #expect(groups.inProgress.isEmpty)
    }

    @Test("lanes run in the order work moves, and the titles are the column titles")
    func orderAndTitles() {
        #expect(JiraLane.allCases.sorted() == [.toDo, .inProgress, .reviewing, .testing, .done])
        #expect(JiraLane.allCases.map(\.title)
            == ["To do", "In progress", "Reviewing", "Testing", "Done"])
    }

    @Test("an issue's lane is its status's lane")
    func issueLane() {
        let issue = JiraIssue(
            key: "ACME-1", summary: "s", statusName: "Reviewing",
            statusCategory: .inProgress, issueType: "Task", updatedAt: .distantPast
        )
        #expect(JiraGrouping.lane(for: issue) == .reviewing)
    }

    @Test("every board column carries the lane it shows")
    func columnsCarryLanes() {
        let groups = JiraGroups(toDo: [], inProgress: [], reviewing: [], testing: [], done: [])
        #expect(groups.boardColumns(includesDone: true).map(\.lane) == JiraLane.allCases)
    }
}
