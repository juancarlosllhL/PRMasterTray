import Foundation
import Testing
@testable import PRMasterCore

private let moment = Date(timeIntervalSince1970: 1_000_000)

private func searchable(
    _ key: String,
    _ summary: String,
    category: JiraStatusCategory = .inProgress,
    status: String = "In Progress"
) -> JiraIssue {
    JiraIssue(
        key: key, summary: summary, statusName: status, statusCategory: category,
        issueType: "Task", priority: .medium, updatedAt: moment,
        categoryChangedAt: moment
    )
}

@Suite("JiraSearch")
struct JiraSearchTests {

    private let issue = searchable("ACME-60798", "Extract pure análisis logic")

    @Test("an empty query matches everything", arguments: ["", "   ", "\t"])
    func emptyMatches(query: String) {
        #expect(JiraSearch.matches(issue, query: query))
    }

    @Test("the key matches whole or in part", arguments: [
        "ACME-60798", "acme-60798", "60798", "acme",
    ])
    func keyMatches(query: String) {
        #expect(JiraSearch.matches(issue, query: query))
    }

    @Test("the summary matches on any run of characters", arguments: [
        "extract", "PURE", "logic", "ct pure",
    ])
    func summaryMatches(query: String) {
        #expect(JiraSearch.matches(issue, query: query))
    }

    /// Typed on a keyboard in a hurry, the accent is the first thing to go.
    @Test("accents are ignored in both directions", arguments: [
        "analisis", "análisis", "ANALISIS",
    ])
    func accentsIgnored(query: String) {
        #expect(JiraSearch.matches(issue, query: query))
    }

    /// Words are narrowing terms, not a phrase, so they need not be adjacent or
    /// in the order typed.
    @Test("every word has to match, wherever it appears", arguments: [
        "extract logic", "logic extract", "60798 pure",
    ])
    func allWordsMustMatch(query: String) {
        #expect(JiraSearch.matches(issue, query: query))
    }

    @Test("one word missing rejects the issue", arguments: [
        "extract missing", "widget", "60799",
    ])
    func missingWordRejects(query: String) {
        #expect(!JiraSearch.matches(issue, query: query))
    }

    /// The status and the type are shown on the row but are not searched: they
    /// are a handful of repeated words that would match half the list at once.
    @Test("only the key and the summary are searched")
    func onlyKeyAndSummary() {
        #expect(!JiraSearch.matches(issue, query: "progress"))
        #expect(!JiraSearch.matches(issue, query: "task"))
    }
}

@Suite("JiraGroups filtering")
struct JiraGroupsFilteringTests {

    private var groups: JiraGroups {
        JiraGrouping.group(
            [
                searchable("ACME-1", "widget rename", category: .toDo, status: "To Do"),
                searchable("ACME-2", "widget colours"),
                searchable("ACME-3", "gadget rewiring", status: "Testing"),
                searchable("ACME-4", "widget audit", category: .done),
            ],
            window: .twoWeeks, now: moment
        )
    }

    @Test("the query reaches every section at once")
    func everySection() {
        let found = groups.matching("widget")

        #expect(found.toDo.map(\.key) == ["ACME-1"])
        #expect(found.inProgress.map(\.key) == ["ACME-2"])
        #expect(found.testing.isEmpty)
        #expect(found.done.map(\.key) == ["ACME-4"])
        #expect(found.count == 3)
    }

    @Test("an empty query leaves the groups as they were")
    func emptyQueryKeepsAll() {
        #expect(groups.matching("") == groups)
        #expect(groups.matching("  ") == groups)
    }

    @Test("a query nothing matches empties the pane")
    func noMatches() {
        let found = groups.matching("nothing here")
        #expect(found.isEmpty)
        #expect(found.count == 0)
    }
}
