import Foundation
import Testing
@testable import PRMasterCore

@Suite("Jira issue key in a pull request title")
struct JiraIssueKeyTests {

    @Test("finds the key wherever the team's title conventions put it", arguments: [
        (":sparkles: ACME-64823: expose the Luzmo plugin SSE subscriptions server", "ACME-64823"),
        (":construction_worker: migrate Apollo checks to apollo-checks orb (ACME-61915)", "ACME-61915"),
        (":sparkles: [ACME-63187] prd: enable VULNERABILITIES_SKIP_UNCHANGED", "ACME-63187"),
        (":memo: ACME-63187 Document the production results", "ACME-63187"),
        ("POC-12345/spike the new board", "POC-12345"),
        ("feat: CDKC-42 and ACME-7 together", "CDKC-42"),
    ])
    func found(title: String, key: String) {
        #expect(JiraIssueKey.first(in: title) == key)
    }

    /// A menu offering to open UTF-8 in Jira would be a broken link on every click.
    @Test("ignores look-alikes that are not issues", arguments: [
        ":bug: prefix CSV large exports with a UTF-8 BOM",
        ":memo: RFC-002 Nova table parity with Luzmo regular-table",
        ":sparkles: add cryostat app to devtools [ACME-0]",
        "bump XACME-123 and ACME-12x",
        "acme-64823: lowercase is a branch habit, not a title one",
        "chore: kafka analysis reports for stg-euw1",
    ])
    func ignored(title: String) {
        #expect(JiraIssueKey.first(in: title) == nil)
    }

    @Test("the link is the key's browse page on the signed-in site")
    func browseURL() throws {
        let base = try #require(URL(string: "https://lansweeper.atlassian.net"))
        #expect(JiraIssueKey.browseURL("ACME-64823", on: base).absoluteString
            == "https://lansweeper.atlassian.net/browse/ACME-64823")
    }
}
