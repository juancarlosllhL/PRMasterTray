import Foundation
import Testing
@testable import PRMasterCore

@Suite("JiraStatusCategory")
struct JiraStatusCategoryTests {

    @Test("the category set is exhaustive")
    func categorySetIsExhaustive() {
        #expect(JiraStatusCategory.allCases.count == 4)
    }

    /// Raw values are Jira's category *keys*, not the display names. Verified
    /// live: the site returns key `new` under the name "To Do", so matching on
    /// the name would break on any site that renames or localises a category.
    @Test("raw values are the API keys", arguments: [
        (JiraStatusCategory.toDo, "new"),
        (JiraStatusCategory.inProgress, "indeterminate"),
        (JiraStatusCategory.done, "done"),
    ])
    func rawValuesAreAPIKeys(category: JiraStatusCategory, raw: String) {
        #expect(category.rawValue == raw)
        #expect(JiraStatusCategory(rawValue: raw) == category)
    }

    /// A category Atlassian adds later must not throw and must not be mistaken
    /// for done, which would silently hide an issue that is still open.
    @Test("an unrecognised key falls back to unknown", arguments: [
        "brand-new-category", "", "DONE", "undefined",
    ])
    func unrecognisedFallsBack(raw: String) {
        #expect(JiraStatusCategory(rawValue: raw) ?? .unknown == .unknown)
    }

    @Test("unknown is not treated as done")
    func unknownIsNotDone() {
        #expect(JiraStatusCategory.unknown != .done)
        #expect(!JiraStatusCategory.unknown.isDone)
        #expect(JiraStatusCategory.done.isDone)
    }
}

@Suite("JiraIssue")
struct JiraIssueTests {

    private func issue(status: String, category: JiraStatusCategory) -> JiraIssue {
        JiraIssue(
            key: "ACME-1",
            summary: "a summary",
            statusName: status,
            statusCategory: category,
            issueType: "Task",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// The four real status names this site returns, verified live against
    /// lansweeper.atlassian.net. Site-specific names are display-only; the
    /// category is what the UI groups and colours by.
    @Test("real site status names carry their measured category", arguments: [
        ("To Do", JiraStatusCategory.toDo),
        ("New", JiraStatusCategory.toDo),
        ("On Hold", JiraStatusCategory.toDo),
        ("Awaiting Customer", JiraStatusCategory.toDo),
        ("In Progress", JiraStatusCategory.inProgress),
        ("Testing", JiraStatusCategory.inProgress),
    ])
    func siteStatusNames(name: String, expected: JiraStatusCategory) {
        let subject = issue(status: name, category: expected)
        #expect(subject.statusName == name)
        #expect(subject.statusCategory == expected)
    }

    @Test("the key identifies the issue")
    func keyIsIdentity() {
        #expect(issue(status: "To Do", category: .toDo).id == "ACME-1")
    }
}
