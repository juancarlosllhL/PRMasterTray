import Foundation
import Testing
@testable import PRMasterCore

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
    func popoverWidth(isBoardTab: Bool, showsBoard: Bool, expected: Double) {
        #expect(
            JiraBoard.popoverWidth(
                isBoardTab: isBoardTab, showsBoard: showsBoard,
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
