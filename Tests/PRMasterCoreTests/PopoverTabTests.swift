import Foundation
import Testing
@testable import PRMasterCore

@Suite("PopoverTab")
struct PopoverTabTests {

    // MARK: identity

    @Test("every case has a distinct label and symbol")
    func labelsAndSymbolsAreDistinct() {
        let labels = PopoverTab.allCases.map(\.label)
        let symbols = PopoverTab.allCases.map(\.symbolName)

        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == PopoverTab.allCases.count)
        #expect(Set(symbols).count == PopoverTab.allCases.count)
    }

    /// Guards the tables below: a fifth tab has to be given a visibility rule and
    /// a keyboard position deliberately rather than inheriting a switch default.
    @Test("the tab set is exhaustive")
    func tabSetIsExhaustive() {
        #expect(PopoverTab.allCases.count == 4)
    }

    /// The raw values reach `UserDefaults` once the selected tab is remembered.
    @Test("raw values are stable", arguments: [
        (PopoverTab.mine, "mine"),
        (PopoverTab.teams, "teams"),
        (PopoverTab.merged, "merged"),
        (PopoverTab.jira, "jira"),
    ])
    func rawValuesAreStable(tab: PopoverTab, raw: String) {
        #expect(tab.rawValue == raw)
        #expect(PopoverTab(rawValue: raw) == tab)
    }

    // MARK: visibility

    @Test("a tab is dropped when its own setting is off", arguments: [
        (MergedWindow.oneDay, ReviewWindow.twoWeeks, true,
         [PopoverTab.mine, .teams, .merged, .jira]),
        (MergedWindow.off, ReviewWindow.twoWeeks, true,
         [PopoverTab.mine, .teams, .jira]),
        (MergedWindow.oneDay, ReviewWindow.off, true,
         [PopoverTab.mine, .merged, .jira]),
        (MergedWindow.oneDay, ReviewWindow.twoWeeks, false,
         [PopoverTab.mine, .teams, .merged]),
        (MergedWindow.off, ReviewWindow.off, false,
         [PopoverTab.mine]),
    ])
    func visibilityDropsDisabledTabs(
        merged: MergedWindow,
        review: ReviewWindow,
        jiraConfigured: Bool,
        expected: [PopoverTab]
    ) {
        let visible = PopoverTab.visible(
            mergedWindow: merged, reviewWindow: review, jiraConfigured: jiraConfigured
        )
        #expect(visible == expected)
    }

    /// Mine being the floor is what makes `resolve` total.
    @Test("mine is never hidden", arguments: MergedWindow.allCases)
    func mineSurvivesEverySetting(merged: MergedWindow) {
        for review in ReviewWindow.allCases {
            for configured in [true, false] {
                let visible = PopoverTab.visible(
                    mergedWindow: merged, reviewWindow: review, jiraConfigured: configured
                )
                #expect(visible.first == .mine)
            }
        }
    }

    /// Fixed order is what lets Command-digit mean the same thing twice running.
    @Test("visible order always follows the declared order")
    func visibleOrderIsStable() {
        for merged in MergedWindow.allCases {
            for review in ReviewWindow.allCases {
                let visible = PopoverTab.visible(
                    mergedWindow: merged, reviewWindow: review, jiraConfigured: true
                )
                #expect(visible == PopoverTab.allCases.filter(visible.contains))
            }
        }
    }

    // MARK: selection fallback

    @Test("a requested tab that is not visible falls back to mine", arguments: [
        PopoverTab.teams, .merged, .jira,
    ])
    func hiddenRequestFallsBack(requested: PopoverTab) {
        #expect(PopoverTab.resolve(requested: requested, visible: [.mine]) == .mine)
    }

    @Test("a visible tab is kept", arguments: PopoverTab.allCases)
    func visibleRequestIsKept(requested: PopoverTab) {
        #expect(PopoverTab.resolve(requested: requested, visible: PopoverTab.allCases) == requested)
    }

    @Test("an empty visible set still resolves")
    func emptyVisibleSetResolvesToMine() {
        #expect(PopoverTab.resolve(requested: .merged, visible: []) == .mine)
    }
}
