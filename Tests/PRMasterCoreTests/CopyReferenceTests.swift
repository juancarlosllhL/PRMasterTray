import Foundation
import Testing
@testable import PRMasterCore

@Suite("Copy references")
struct CopyReferenceTests {

    @Test("an issue's link is its browse page on the signed-in site")
    func issueLink() throws {
        let base = try #require(URL(string: "https://lansweeper.atlassian.net"))
        let issue = JiraIssue(
            key: "ACME-64471", summary: "s", statusName: "In Progress",
            statusCategory: .inProgress, issueType: "Task", updatedAt: .distantPast
        )
        #expect(issue.browseURL(on: base).absoluteString
            == "https://lansweeper.atlassian.net/browse/ACME-64471")
    }

    /// A bare number is ambiguous across repositories. This form GitHub links anywhere.
    @Test("a pull request's ID names its repository and number")
    func pullRequestID() {
        #expect(PullRequestReference.id(repo: "Lansweeper/prmaster", number: 675)
            == "Lansweeper/prmaster#675")
    }
}
