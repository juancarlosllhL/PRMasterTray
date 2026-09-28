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
