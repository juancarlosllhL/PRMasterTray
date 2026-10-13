import Foundation
import Testing
@testable import PRMasterCore

func boardProject(
    _ id: String = "PVT_1",
    title: String = "Platform Board",
    statusFieldID: String? = "PVTSSF_1",
    options: [(String, String)] = [
        ("o-backlog", "Backlog"), ("o-todo", "Todo"), ("o-progress", "In Progress"),
        ("o-review", "In Review"), ("o-qa", "QA"), ("o-blocked", "Blocked"), ("o-done", "Done"),
    ]
) -> GitHubProject {
    GitHubProject(
        id: id, number: 7, title: title, owner: "Lansweeper",
        url: URL(string: "https://github.com/orgs/Lansweeper/projects/7")!,
        statusFieldID: statusFieldID,
        options: options.map { StatusOption(id: $0.0, name: $0.1) }
    )
}

@Suite("ProjectLaneMap")
struct ProjectLaneMapTests {

    @Test("with no override an option goes where its name says")
    func guessed() {
        let map = ProjectLaneMap()
        #expect(map.lane(optionID: "o-review", name: "In Review", in: "PVT_1") == .reviewing)
        #expect(map.lane(optionID: "o-blocked", name: "Blocked", in: "PVT_1") == nil)
    }

    @Test("an override beats the guess, for that project only")
    func overrideWins() {
        var map = ProjectLaneMap()
        map.set(.testing, optionID: "o-review", in: "PVT_1")
        #expect(map.lane(optionID: "o-review", name: "In Review", in: "PVT_1") == .testing)
        #expect(map.lane(optionID: "o-review", name: "In Review", in: "PVT_2") == .reviewing)
    }

    @Test("hidden is an override like any other")
    func hiddenOverride() {
        var map = ProjectLaneMap()
        map.set(.hidden, optionID: "o-todo", in: "PVT_1")
        #expect(map.lane(optionID: "o-todo", name: "Todo", in: "PVT_1") == nil)
    }

    /// Keyed by option id, which survives the board's owner renaming the column.
    @Test("an override survives the option being renamed")
    func survivesRename() {
        var map = ProjectLaneMap()
        map.set(.done, optionID: "o-qa", in: "PVT_1")
        #expect(map.lane(optionID: "o-qa", name: "Quality gate", in: "PVT_1") == .done)
    }

    @Test("an override for a deleted option applies to nothing")
    func deletedOption() {
        var map = ProjectLaneMap()
        map.set(.done, optionID: "o-gone", in: "PVT_1")
        let project = boardProject()
        func lanes(_ map: ProjectLaneMap) -> [BoardLane?] {
            project.options.map { map.lane(optionID: $0.id, name: $0.name, in: project.id) }
        }
        #expect(lanes(map) == lanes(ProjectLaneMap()))
    }

    /// Not yet triaged, so not yet work; GitHub's own board parks these in "No Status".
    @Test("an item with no Status is hidden until told otherwise")
    func noStatus() {
        var map = ProjectLaneMap()
        #expect(map.lane(optionID: nil, name: nil, in: "PVT_1") == nil)
        map.set(.toDo, optionID: ProjectLaneMap.noStatus, in: "PVT_1")
        #expect(map.lane(optionID: nil, name: nil, in: "PVT_1") == .toDo)
    }

    @Test("the choice shown in Settings is the override, or else the guess")
    func choice() {
        var map = ProjectLaneMap()
        #expect(map.choice(optionID: "o-blocked", name: "Blocked", in: "PVT_1") == .hidden)
        #expect(map.choice(optionID: "o-qa", name: "QA", in: "PVT_1") == .testing)
        map.set(.inProgress, optionID: "o-qa", in: "PVT_1")
        #expect(map.choice(optionID: "o-qa", name: "QA", in: "PVT_1") == .inProgress)
    }

    @Test("a move lands on the option named like the column")
    func targetPrefersName() {
        let project = boardProject(options: [("o-ready", "Ready"), ("o-todo", "To do"), ("o-done", "Done")])
        #expect(ProjectLaneMap().target(for: .toDo, in: project)?.id == "o-todo")
    }

    @Test("otherwise a move lands on the first option in board order")
    func targetFallsBackToOrder() {
        let project = boardProject(options: [("o-ready", "Ready"), ("o-todo", "Todo"), ("o-done", "Done")])
        #expect(ProjectLaneMap().target(for: .toDo, in: project)?.id == "o-ready")
    }

    @Test("a move never lands on a hidden-by-default option")
    func hiddenDefaultsNotTargets() {
        let project = boardProject(options: [("o-backlog", "Backlog"), ("o-refine", "In Refinement"), ("o-todo", "Todo")])
        #expect(ProjectLaneMap().target(for: .toDo, in: project)?.id == "o-todo")
    }

    @Test("a column no option maps to has no move target")
    func noTarget() {
        let project = boardProject(options: [("o-todo", "Todo"), ("o-done", "Done")])
        #expect(ProjectLaneMap().target(for: .testing, in: project) == nil)
    }

    @Test("a hidden option is never a move target")
    func hiddenNotTarget() {
        var map = ProjectLaneMap()
        map.set(.hidden, optionID: "o-done", in: "PVT_1")
        #expect(map.target(for: .done, in: boardProject()) == nil)
    }

    @Test("every choice maps to its lane and back", arguments: LaneChoice.allCases)
    func choiceRoundTrip(choice: LaneChoice) {
        #expect(LaneChoice(lane: choice.lane) == choice)
        #expect(!choice.label.isEmpty)
    }
}
