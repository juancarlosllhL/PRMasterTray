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

    @Test("a migrated GitHub issue leads its title with the bracketed key", arguments: [
        ("[ACME-65806] Drop schedule.enabled", "ACME-65806", "Drop schedule.enabled"),
        ("  [PLAT-12]   Tidy the docs", "PLAT-12", "Tidy the docs"),
        ("[ACME-63842] Update TypeScript to 7.1 (deferred from ACME-63703)", "ACME-63842",
         "Update TypeScript to 7.1 (deferred from ACME-63703)"),
    ])
    func leading(title: String, key: String, rest: String) throws {
        let found = try #require(JiraIssueKey.leading(in: title))
        #expect(found.key == key)
        #expect(found.title == rest)
    }

    /// A key mentioned anywhere but the front names a related issue, not the one this copies.
    @Test("only a bracketed key at the very front counts", arguments: [
        "Update TypeScript to 7.1 (deferred from ACME-63703)",
        "ACME-12 without brackets",
        "Fix [ACME-12] later",
        "[Phase 3]-[asset-cortex] Point deployments to the new key",
        "[UTF-8] encode the export",
        "[acme-12] lowercase",
        "[ACME-0] no such issue",
        "[ZZZ-12] not one of our projects",
    ])
    func notLeading(title: String) {
        #expect(JiraIssueKey.leading(in: title) == nil)
    }

    @Test("the link is the key's browse page on the signed-in site")
    func browseURL() throws {
        let base = try #require(URL(string: "https://lansweeper.atlassian.net"))
        #expect(JiraIssueKey.browseURL("ACME-64823", on: base).absoluteString
            == "https://lansweeper.atlassian.net/browse/ACME-64823")
    }
}
