import Foundation
import Testing
@testable import PRMasterCore

private let remark = JiraField(id: "customfield_10170", name: "Remark", kind: .richText)
private let changelog = JiraField(id: "customfield_10039", name: "Changelog", kind: .richText)
private let changelogStatus = JiraField(
    id: "customfield_10346", name: "Changelog status", kind: .option(["Internal", "External"])
)

@Suite("JiraField")
struct JiraFieldTests {

    @Test("a Remark only has to say something, with or without PM:", arguments: [
        ("PM: Permissions were lost in the UI 2.0 migration", true),
        ("Permissions were lost", true),
        ("PM:", false),
        ("pm:   ", false),
        ("", false),
    ])
    func remarkNeedsText(value: String, valid: Bool) {
        #expect((remark.problem(with: value) == nil) == valid)
    }

    /// Every one of the last 60 ACME bugs past Reviewing opens its Remark with PM:,
    /// so the app adds it rather than make the user remember.
    @Test("PM: is added to a Remark that lacks it and left alone otherwise", arguments: [
        ("Permissions were lost", "PM: Permissions were lost"),
        ("  Permissions were lost \n", "PM: Permissions were lost"),
        ("PM: Permissions were lost", "PM: Permissions were lost"),
        ("PM:Problem: never migrated", "PM:Problem: never migrated"),
        ("pm: lower case", "PM: lower case"),
    ])
    func remarkPrefix(typed: String, sent: String) {
        #expect(remark.normalized(typed) == sent)
    }

    @Test("other fields are sent as typed, only trimmed")
    func othersUntouched() {
        #expect(changelog.normalized(" Fixed a crash. ") == "Fixed a crash.")
        #expect(changelogStatus.normalized("Internal") == "Internal")
    }

    /// Only 4 of those 60 changelogs start with PM:, the rest read "Fixed …".
    @Test("a Changelog is a plain sentence with no prefix")
    func changelogHasNoPrefix() {
        #expect(changelog.problem(with: "Fixed a crash on the asset page.") == nil)
        #expect(changelog.problem(with: "  \n ") != nil)
    }

    @Test("a select only takes one of Jira's own values")
    func optionMustBeAllowed() {
        #expect(changelogStatus.problem(with: "Internal") == nil)
        #expect(changelogStatus.problem(with: "Customer") != nil)
        #expect(changelogStatus.problem(with: "") != nil)
    }

    /// Jira's v3 API refuses a plain string for a multi-line text field.
    @Test("rich text goes out as a document, one paragraph per line")
    func richTextIsADocument() throws {
        let encoded = JiraField.encode("First line\n\nThird line", as: .richText)
        let doc = try #require(encoded as? [String: Any])
        #expect(doc["type"] as? String == "doc")
        #expect(doc["version"] as? Int == 1)
        let paragraphs = try #require(doc["content"] as? [[String: Any]])
        let texts = paragraphs.map { paragraph in
            (paragraph["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        }
        #expect(texts == [["First line"], [], ["Third line"]])
    }

    @Test("a select goes out as its value, plain text as itself")
    func otherEncodings() {
        #expect(JiraField.encode("Internal", as: .option(["Internal"])) as? [String: String]
            == ["value": "Internal"])
        #expect(JiraField.encode("x", as: .text) as? String == "x")
    }

    @Test("a request lists the problem with each field it asks for")
    func requestProblems() {
        let request = JiraFieldRequest(
            key: "ACME-1",
            from: JiraStatus(name: "Reviewing", category: .inProgress),
            to: JiraStatus(name: "Testing", category: .inProgress),
            fields: [changelogStatus, changelog, remark]
        )
        let problems = request.problems(in: [
            "customfield_10346": "Internal", "customfield_10039": "Fixed it.", "customfield_10170": "PM:",
        ])
        #expect(Array(problems.keys) == ["customfield_10170"])
        #expect(request.problems(in: [:]).count == 3)
    }
}
