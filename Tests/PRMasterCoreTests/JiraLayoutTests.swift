import Foundation
import Testing
@testable import PRMasterCore

@Suite("JiraLayout")
struct JiraLayoutTests {

    @Test("the layout set is exhaustive")
    func exhaustive() {
        #expect(JiraLayout.allCases.count == 2)
    }

    /// The raw values are a storage contract: renaming one resets every install
    /// that had chosen the other.
    @Test("raw values are stable", arguments: [
        (JiraLayout.list, "list"),
        (JiraLayout.board, "board"),
    ])
    func rawValues(layout: JiraLayout, raw: String) {
        #expect(layout.rawValue == raw)
        #expect(JiraLayout(rawValue: raw) == layout)
    }

    @Test("every layout has a label")
    func labels() {
        #expect(JiraLayout.list.label == "List")
        #expect(JiraLayout.board.label == "Board")
    }

    @Test("the list is the default")
    func defaultIsList() {
        #expect(JiraLayout.default == .list)
    }

    @Test("an absent key reads as the list")
    func absentKeyReadsAsList() {
        let defaults = UserDefaults(suiteName: "JiraLayoutTests.absent")!
        defaults.removePersistentDomain(forName: "JiraLayoutTests.absent")
        #expect(UserDefaultsPreferences(defaults: defaults).jiraLayout() == .list)
    }

    @Test("an unrecognised value reads as the list")
    func unknownValueReadsAsList() {
        let defaults = UserDefaults(suiteName: "JiraLayoutTests.unknown")!
        defaults.removePersistentDomain(forName: "JiraLayoutTests.unknown")
        defaults.set("kanban", forKey: "jiraLayout")
        #expect(UserDefaultsPreferences(defaults: defaults).jiraLayout() == .list)
    }

    /// A suite per case: the arguments run in parallel, and one shared domain
    /// makes each case read whatever the other wrote.
    @Test("a stored value survives a round trip", arguments: JiraLayout.allCases)
    func roundTrip(layout: JiraLayout) {
        let name = "JiraLayoutTests.roundTrip.\(layout.rawValue)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = UserDefaultsPreferences(defaults: defaults)
        preferences.setJiraLayout(layout)
        #expect(preferences.jiraLayout() == layout)
    }
}
