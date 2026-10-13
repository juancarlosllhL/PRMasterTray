import Foundation
import Testing
@testable import PRMasterCore

@Suite("BoardLane guess")
struct BoardLaneGuessTests {

    /// GitHub's own defaults first, then names teams give their columns.
    static let names: [(String, BoardLane?)] = [
        ("Todo", .toDo),
        ("To do", .toDo),
        ("Backlog", nil),
        ("Ready", .toDo),
        ("New", .toDo),
        ("In Refinement", nil),
        ("Draft", .toDo),
        ("In Progress", .inProgress),
        ("Doing", .inProgress),
        ("In Review", .reviewing),
        ("Code review", .reviewing),
        ("QA", .testing),
        ("Testing", .testing),
        ("Ready for QA", .testing),
        ("Ready for review", .reviewing),
        ("Done", .done),
        ("Closed", .done),
        ("Released", .done),
        ("Blocked", nil),
        ("On hold", nil),
        ("Won't do", nil),
        ("Cancelled", nil),
        ("Latest", .inProgress),
        ("Contested", .inProgress),
        ("Icebox", .inProgress),
        ("", .inProgress),
    ]

    @Test("a Status option's name picks the column it lands in", arguments: names)
    func guess(name: String, expected: BoardLane?) {
        #expect(BoardLane.guess(optionName: name) == expected)
    }

    @Test("case and punctuation do not change the guess")
    func folding() {
        #expect(BoardLane.guess(optionName: "  IN-REVIEW ") == .reviewing)
        #expect(BoardLane.guess(optionName: "done ✅") == .done)
    }
}
