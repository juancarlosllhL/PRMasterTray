import Foundation
import Testing
@testable import PRMasterCore

private final class CountingIssueClient: JiraIssueFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var fetchCount: Int { lock.withLock { count } }

    func fetchAssignedIssues(within window: JiraWindow) async throws -> [JiraIssue] {
        lock.withLock { count += 1 }
        return []
    }
}

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

    @MainActor
    @Test("the store reads the stored layout at launch")
    func storeReadsAtLaunch() {
        let preferences = MemoryPreferences()
        preferences.setJiraLayout(.board)
        #expect(JiraStore(issues: nil, links: nil, preferences: preferences).layout == .board)
    }

    @MainActor
    @Test("assigning the layout writes it through")
    func assignmentWritesThrough() {
        let preferences = MemoryPreferences()
        let store = JiraStore(issues: nil, links: nil, preferences: preferences)

        store.layout = .board

        #expect(preferences.jiraLayout() == .board)
    }

    /// Unlike `window`, the layout changes nothing about the query, so it must
    /// not cost a fetch.
    @MainActor
    @Test("changing the layout does not refetch")
    func assignmentDoesNotRefetch() async {
        let client = CountingIssueClient()
        let store = JiraStore(issues: client, links: nil, preferences: MemoryPreferences())

        store.layout = .board
        await Task.yield()

        #expect(client.fetchCount == 0)
    }
}
