import Foundation
import Testing
@testable import PRMasterCore

@Suite("Jira issue type colours")
struct JiraIssueTypeTests {

    @Test("each kind of work gets its own colour", arguments: [
        ("Story", ReadinessTint.green),
        ("Task", .blue),
        ("Sub-task", .blue),
        ("Bug", .red),
        ("Customer Support Ticket", .yellow),
        ("Epic", .gray),
        ("Spike", .gray),
        ("", .gray),
    ])
    func tints(name: String, expected: ReadinessTint) {
        #expect(JiraIssueType.tint(for: name) == expected)
    }

    /// Sites rename and re-case their types freely.
    @Test("the match ignores case and surrounding space", arguments: [
        "bug", "BUG", "  Bug  ",
    ])
    func casingDoesNotMatter(name: String) {
        #expect(JiraIssueType.tint(for: name) == .red)
    }

    /// "Support Ticket", "Customer Support" and similar all mean the same desk.
    @Test("anything a support desk raises is yellow", arguments: [
        "Support Ticket", "Customer Support", "Support Request",
    ])
    func supportVariants(name: String) {
        #expect(JiraIssueType.tint(for: name) == .yellow)
    }

    /// Sub-tasks and technical tasks are still tasks.
    @Test("a compound name still matches its kind", arguments: [
        ("Technical Task", ReadinessTint.blue),
        ("Sub-bug", .red),
        ("User Story", .green),
    ])
    func compoundNames(name: String, expected: ReadinessTint) {
        #expect(JiraIssueType.tint(for: name) == expected)
    }
}

/// The longest type name on the row, and the one that crowds out the status.
@Suite("Jira issue type names")
struct JiraIssueTypeNameTests {

    @Test("a support ticket is abbreviated", arguments: [
        "Customer Support Ticket", "Support Ticket", "customer support",
    ])
    func supportIsShortened(name: String) {
        #expect(JiraIssueType.shortName(for: name) == "CST")
    }

    @Test("every other type is shown as the site names it", arguments: [
        "Task", "Bug", "Story", "Sub-task", "Epic", "Spike",
    ])
    func othersAreUntouched(name: String) {
        #expect(JiraIssueType.shortName(for: name) == name)
    }

    @Test("surrounding space is dropped")
    func spaceIsTrimmed() {
        #expect(JiraIssueType.shortName(for: "  Bug  ") == "Bug")
    }
}
