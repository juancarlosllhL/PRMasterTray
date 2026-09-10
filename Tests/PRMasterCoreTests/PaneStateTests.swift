import Foundation
import Testing
@testable import PRMasterCore

@Suite("PaneState.resolve")
struct PaneStateTests {

    private static let fetched = Date(timeIntervalSince1970: 1_000)
    private static let failure = PRMasterError.network(URLError(.timedOut))

    @Test("the state set is exhaustive")
    func stateSetIsExhaustive() {
        #expect(PaneState.allCases.count == 6)
    }

    /// The whole table in the order the old `content` branch checked it.
    @Test("every input combination resolves", arguments: [
        (0, 0, false, false, PaneState.loading),
        (0, 3, false, false, PaneState.loading),
        (0, 0, false, true, PaneState.empty),
        (0, 3, false, true, PaneState.emptyByFilter),
        (0, 0, true, false, PaneState.failed),
        (0, 0, true, true, PaneState.failed),
        (0, 3, true, true, PaneState.failed),
        (5, 0, false, false, PaneState.content),
        (5, 0, false, true, PaneState.content),
        (5, 3, false, true, PaneState.content),
        (5, 0, true, true, PaneState.stale),
        (5, 3, true, true, PaneState.stale),
        (5, 0, true, false, PaneState.stale),
    ])
    func resolvesEveryCombination(
        rowCount: Int,
        hiddenCount: Int,
        hasError: Bool,
        hasFetched: Bool,
        expected: PaneState
    ) {
        let state = PaneState.resolve(
            rowCount: rowCount,
            hiddenCount: hiddenCount,
            lastError: hasError ? Self.failure : nil,
            lastSuccessfulFetch: hasFetched ? Self.fetched : nil
        )
        #expect(state == expected)
    }

    /// The regression FOLLOWUP.md records: a first-fetch failure once sat on
    /// "Loading…" forever because the branches were in the wrong order.
    @Test("a first-fetch failure is failed, never loading")
    func firstFetchFailureIsNotLoading() {
        let state = PaneState.resolve(
            rowCount: 0, hiddenCount: 0, lastError: Self.failure, lastSuccessfulFetch: nil
        )
        #expect(state == .failed)
        #expect(state != .loading)
    }

    /// Stale beats blank: rows already on screen are never replaced by an error.
    @Test("data plus an error is stale, never failed", arguments: [1, 5, 100])
    func dataPlusErrorIsStale(rowCount: Int) {
        let state = PaneState.resolve(
            rowCount: rowCount, hiddenCount: 0,
            lastError: Self.failure, lastSuccessfulFetch: Self.fetched
        )
        #expect(state == .stale)
    }

    /// `hiddenCount` only speaks when the list is empty; it must not turn a
    /// populated pane into a filter message.
    @Test("hiddenCount is ignored once there are rows", arguments: [0, 1, 50])
    func hiddenCountIgnoredWithRows(hiddenCount: Int) {
        let state = PaneState.resolve(
            rowCount: 2, hiddenCount: hiddenCount, lastError: nil, lastSuccessfulFetch: Self.fetched
        )
        #expect(state == .content)
    }

    /// Claiming "nothing to show" while the filter is what emptied the list is
    /// the lie this case exists to prevent.
    @Test("an empty list with hidden rows blames the filter")
    func emptyWithHiddenBlamesFilter() {
        let state = PaneState.resolve(
            rowCount: 0, hiddenCount: 1, lastError: nil, lastSuccessfulFetch: Self.fetched
        )
        #expect(state == .emptyByFilter)
    }

    @Test("only content and stale show rows", arguments: PaneState.allCases)
    func showsRowsMatchesState(state: PaneState) {
        #expect(state.showsRows == (state == .content || state == .stale))
    }
}
