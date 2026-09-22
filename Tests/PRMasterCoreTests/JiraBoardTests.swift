import Foundation
import Testing
@testable import PRMasterCore

private let boardNow = Date(timeIntervalSince1970: 2_000_000)

private func boardIssue(
    _ key: String,
    category: JiraStatusCategory = .toDo,
    priority: JiraPriority = .medium,
    status: String = "To Do",
    doneDaysAgo: Double? = nil
) -> JiraIssue {
    JiraIssue(
        key: key,
        summary: "summary for \(key)",
        statusName: status,
        statusCategory: category,
        issueType: "Task",
        priority: priority,
        updatedAt: boardNow,
        categoryChangedAt: doneDaysAgo.map { boardNow.addingTimeInterval(-$0 * 86_400) }
    )
}

private let populated = JiraGrouping.group(
    [
        boardIssue("ACME-1"),
        boardIssue("ACME-2", category: .inProgress, status: "In Progress"),
        boardIssue("ACME-3", category: .inProgress, status: "Testing"),
        boardIssue("ACME-4", category: .done, status: "Done", doneDaysAgo: 1),
    ],
    window: .twoWeeks,
    now: boardNow
)

@Suite("JiraColumn")
struct JiraColumnTests {

    @Test("columns read left to right in the order the work moves")
    func workflowOrder() {
        #expect(
            populated.boardColumns(includesDone: true).map(\.title)
                == ["To do", "In progress", "Testing", "Done"]
        )
    }

    @Test("every column carries its own issues")
    func issuesPerColumn() {
        let columns = populated.boardColumns(includesDone: true)
        #expect(columns.map { $0.issues.map(\.key) }
            == [["ACME-1"], ["ACME-2"], ["ACME-3"], ["ACME-4"]])
    }

    /// The list drops an empty section. A board must not: an empty column is
    /// what says the group exists and has nothing in it.
    @Test("an empty group still gets a column")
    func emptyGroupsSurvive() {
        let onlyToDo = JiraGrouping.group([boardIssue("ACME-1")], window: .twoWeeks, now: boardNow)
        let columns = onlyToDo.boardColumns(includesDone: true)

        #expect(columns.count == 4)
        #expect(columns.map(\.issues.isEmpty) == [false, true, true, true])
    }

    @Test("no issues at all still gives every column")
    func emptyBoardKeepsColumns() {
        let none = JiraGrouping.group([], window: .twoWeeks, now: boardNow)
        #expect(none.boardColumns(includesDone: true).count == 4)
        #expect(none.boardColumns(includesDone: false).count == 3)
    }

    /// A column that can never fill would read as a bug rather than as a window
    /// that is switched off.
    @Test("Done is dropped when its window is off")
    func doneDroppedWhenOff() {
        let columns = populated.boardColumns(includesDone: false)
        #expect(columns.map(\.title) == ["To do", "In progress", "Testing"])
    }

    @Test("Done is the only column without priority")
    func priorityShownExceptOnDone() {
        let columns = populated.boardColumns(includesDone: true)
        #expect(columns.map(\.showsPriority) == [true, true, true, false])
    }

    @Test("a column is identified by its title")
    func identifiedByTitle() {
        let columns = populated.boardColumns(includesDone: true)
        #expect(columns.map(\.id) == columns.map(\.title))
        #expect(Set(columns.map(\.id)).count == columns.count)
    }

    /// Ordering belongs to `JiraGrouping`, and reading it through a column must
    /// not disturb it.
    @Test("ordering inside a column is whatever the grouping decided")
    func orderingUntouched() {
        let groups = JiraGrouping.group(
            [
                boardIssue("ACME-9", priority: .low),
                boardIssue("ACME-8", priority: .critical),
                boardIssue("ACME-7", priority: .medium),
            ],
            window: .twoWeeks,
            now: boardNow
        )
        let column = groups.boardColumns(includesDone: true)[0]

        #expect(column.issues.map(\.key) == groups.toDo.map(\.key))
        #expect(column.issues.map(\.key) == ["ACME-8", "ACME-7", "ACME-9"])
    }
}

@Suite("JiraBoard width")
struct JiraBoardWidthTests {

    private static let roomy: Double = 3000

    @Test("four columns take four column widths and three gutters")
    func fourColumns() {
        #expect(
            JiraBoard.width(columns: 4, available: Self.roomy)
                == 4 * JiraBoard.columnWidth + 3 * JiraBoard.gutter + 2 * JiraBoard.outerPadding
        )
    }

    @Test("three columns are narrower than four by one column and one gutter")
    func threeColumns() {
        let three = JiraBoard.width(columns: 3, available: Self.roomy)
        let four = JiraBoard.width(columns: 4, available: Self.roomy)
        #expect(four - three == JiraBoard.columnWidth + JiraBoard.gutter)
    }

    /// A popover measured wider than its display is repositioned by AppKit
    /// rather than shrunk, and lands half off the side.
    @Test("a narrow display clamps the board to what is on it")
    func clampedToScreen() {
        #expect(JiraBoard.width(columns: 4, available: 900) == 900 - JiraBoard.screenMargin)
    }

    @Test("a roomy display is not clamped")
    func notClampedWhenRoomy() {
        #expect(JiraBoard.width(columns: 4, available: Self.roomy) < Self.roomy)
    }

    @Test("no columns means the width the popover always had")
    func noColumns() {
        #expect(JiraBoard.width(columns: 0, available: Self.roomy) == JiraBoard.listWidth)
    }

    /// Clamping must never make the board narrower than the list it replaced.
    @Test("an absurd display still gives at least the list width", arguments: [0.0, 100.0, 380.0])
    func neverBelowListWidth(available: Double) {
        #expect(JiraBoard.width(columns: 4, available: available) == JiraBoard.listWidth)
    }

    @Test("the list width matches what PRListView has always used")
    func listWidthUnchanged() {
        #expect(JiraBoard.listWidth == 380)
    }

    @Test("a negative column count cannot produce a width")
    func negativeColumns() {
        #expect(JiraBoard.width(columns: -1, available: Self.roomy) == JiraBoard.listWidth)
    }
}

@Suite("JiraBoard decisions")
struct JiraBoardDecisionTests {

    private static let roomy: Double = 3000

    @Test("the popover is wide only on the Jira tab showing a board", arguments: [
        (true, true, JiraBoard.width(columns: 4, available: 3000)),
        (true, false, JiraBoard.listWidth),
        (false, true, JiraBoard.listWidth),
        (false, false, JiraBoard.listWidth),
    ])
    func popoverWidth(isJiraTab: Bool, showsBoard: Bool, expected: Double) {
        #expect(
            JiraBoard.popoverWidth(
                isJiraTab: isJiraTab, showsBoard: showsBoard,
                columns: 4, available: Self.roomy
            ) == expected
        )
    }

    @Test("the list summary says nothing about width")
    func listSummary() {
        let summary = JiraBoard.layoutSummary(.list, columns: 4)
        #expect(summary.contains("One section under another"))
        #expect(!summary.contains("column per group"))
    }

    /// The footer's whole job is naming the cost the picker cannot show.
    @Test("the board summary names the column count", arguments: [2, 3, 4])
    func boardSummaryNamesCount(columns: Int) {
        #expect(JiraBoard.layoutSummary(.board, columns: columns).contains("fit \(columns) of them"))
    }

    @Test("every link state has its own card wording")
    func cardLinkSummaries() {
        #expect(JiraBoard.cardLinkSummary(.loading, count: 0) == "Checking…")
        #expect(JiraBoard.cardLinkSummary(.unknown, count: 0) == "Couldn't check")
        #expect(JiraBoard.cardLinkSummary(.none, count: 0) == "No PRs")
    }

    /// "Couldn't check" and "No PRs" must never read alike: the first is an
    /// admission, the second a fact, and confusing them is a lie.
    @Test("no two link states read the same")
    func linkSummariesAreDistinct() {
        let wordings = IssueLinkState.allCases.map { JiraBoard.cardLinkSummary($0, count: 2) }
        #expect(Set(wordings).count == IssueLinkState.allCases.count)
    }

    @Test("one pull request is not pluralised")
    func singularLink() {
        #expect(JiraBoard.cardLinkSummary(.linked, count: 1) == "1 pull request")
        #expect(JiraBoard.cardLinkSummary(.linked, count: 2) == "2 pull requests")
    }
}

@Suite("JiraStore board reading")
@MainActor
struct JiraStoreBoardTests {

    @Test("the store drops Done when the window is off")
    func storeHonoursWindow() {
        let preferences = MemoryPreferences()
        preferences.setJiraWindow(.off)
        let store = JiraStore(issues: nil, links: nil, preferences: preferences)

        #expect(store.boardColumns.map(\.title) == ["To do", "In progress", "Testing"])
    }

    @Test("the board is off while the layout is the list")
    func noBoardInListLayout() {
        #expect(JiraStore(issues: nil, links: nil, preferences: MemoryPreferences()).showsBoard == false)
    }

    /// A wide popover over "Jira isn't set up yet" would be absurd, and a wide
    /// one over nothing at all no less so.
    @Test("the board is off while Jira is unconfigured")
    func noBoardWhenUnconfigured() {
        let preferences = MemoryPreferences()
        preferences.setJiraLayout(.board)
        #expect(JiraStore(issues: nil, links: nil, preferences: preferences).showsBoard == false)
    }
}
