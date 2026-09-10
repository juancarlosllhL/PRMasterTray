import Foundation
import Testing
@testable import PRMasterCore

@Suite("TabSelectionStore")
@MainActor
struct TabSelectionStoreTests {

    @Test("opens on pull requests")
    func opensOnPullRequests() {
        #expect(TabSelectionStore().selected == .pullRequests)
    }

    @Test("selecting a tab sticks")
    func selectingSticks() {
        let store = TabSelectionStore()
        store.select(.jira)
        #expect(store.selected == .jira)
    }

    @Test("a digit indexes into the visible tabs", arguments: [
        (0, PopoverTab.pullRequests),
        (1, PopoverTab.jira),
    ])
    func digitIndexesVisible(index: Int, expected: PopoverTab) {
        let store = TabSelectionStore()
        store.select(at: index, in: PopoverTab.allCases)
        #expect(store.selected == expected)
    }

    @Test("an out-of-range digit changes nothing", arguments: [-1, 2, 99])
    func outOfRangeIsIgnored(index: Int) {
        let store = TabSelectionStore()
        store.select(.jira)
        store.select(at: index, in: PopoverTab.allCases)
        #expect(store.selected == .jira)
    }

    @Test("a selection whose tab disappeared resolves back to the default")
    func vanishedSelectionResolves() {
        let store = TabSelectionStore()
        store.select(.jira)
        #expect(store.resolved(visible: [.pullRequests]) == .pullRequests)
        #expect(store.resolved(visible: PopoverTab.allCases) == .jira)
    }

    /// Resolving is a read, not a write: the original choice comes back if the
    /// tab is offered again.
    @Test("resolving does not overwrite the stored choice")
    func resolvingDoesNotMutate() {
        let store = TabSelectionStore()
        store.select(.jira)
        _ = store.resolved(visible: [.pullRequests])
        #expect(store.selected == .jira)
        #expect(store.resolved(visible: PopoverTab.allCases) == .jira)
    }
}
