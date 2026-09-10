import Foundation
import Testing
@testable import PRMasterCore

@Suite("PopoverTab")
struct PopoverTabTests {

    @Test("every case has a distinct label and symbol")
    func labelsAndSymbolsAreDistinct() {
        let labels = PopoverTab.allCases.map(\.label)
        let symbols = PopoverTab.allCases.map(\.symbolName)

        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == PopoverTab.allCases.count)
        #expect(Set(symbols).count == PopoverTab.allCases.count)
    }

    /// Guards the switches below: a third tab has to be given a pane and a
    /// keyboard position deliberately rather than inheriting a default.
    @Test("the tab set is exhaustive")
    func tabSetIsExhaustive() {
        #expect(PopoverTab.allCases.count == 2)
    }

    /// The existing sections stay stacked in one pane rather than being split
    /// across tabs, so the only tab beside them is Jira.
    @Test("pull requests comes first and is the default")
    func pullRequestsIsFirst() {
        #expect(PopoverTab.allCases.first == .pullRequests)
        #expect(PopoverTab.default == .pullRequests)
    }

    /// The raw values reach `UserDefaults` once the selected tab is remembered.
    @Test("raw values are stable", arguments: [
        (PopoverTab.pullRequests, "pullRequests"),
        (PopoverTab.jira, "jira"),
    ])
    func rawValuesAreStable(tab: PopoverTab, raw: String) {
        #expect(tab.rawValue == raw)
        #expect(PopoverTab(rawValue: raw) == tab)
    }

    @Test("a visible tab is kept", arguments: PopoverTab.allCases)
    func visibleRequestIsKept(requested: PopoverTab) {
        #expect(PopoverTab.resolve(requested: requested, visible: PopoverTab.allCases) == requested)
    }

    @Test("a tab that is not on offer falls back to the default")
    func hiddenRequestFallsBack() {
        #expect(PopoverTab.resolve(requested: .jira, visible: [.pullRequests]) == .pullRequests)
        #expect(PopoverTab.resolve(requested: .jira, visible: []) == .pullRequests)
    }
}
