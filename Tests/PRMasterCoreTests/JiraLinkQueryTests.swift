import Foundation
import Testing
@testable import PRMasterCore

@Suite("Queries.pullRequestsForIssueKeys")
struct JiraLinkQueryTests {

    /// Nothing to ask means no round trip at all, the rule every other builder
    /// in this file follows.
    @Test("an empty key list yields nil")
    func emptyYieldsNil() {
        #expect(Queries.pullRequestsForIssueKeys([]) == nil)
    }

    @Test("one alias per key")
    func oneAliasPerKey() throws {
        let built = try #require(Queries.pullRequestsForIssueKeys(["ACME-1", "ACME-2", "ACME-3"]))
        #expect(built.query.contains("k0: search("))
        #expect(built.query.contains("k1: search("))
        #expect(built.query.contains("k2: search("))
        #expect(!built.query.contains("k3: search("))
    }

    /// The rule the rest of Queries enforces: a remote value never reaches the
    /// document text. Only generated aliases and variable names do.
    @Test("keys ride as variables and never enter the document")
    func keysAreVariablesOnly() throws {
        let built = try #require(Queries.pullRequestsForIssueKeys(["ACME-62941"]))
        #expect(!built.query.contains("ACME-62941"))
        #expect(built.variables["q0"] != nil)
    }

    /// Scoped exactly as measured: prefix forms return zero, so a key cannot
    /// pull in a longer key's pull requests.
    @Test("each search is scoped to the key, titles, PRs and the viewer")
    func searchIsScoped() throws {
        let built = try #require(Queries.pullRequestsForIssueKeys(["ACME-1"]))
        let query = try #require(built.variables["q0"])
        #expect(query.contains("ACME-1"))
        #expect(query.contains("in:title"))
        #expect(query.contains("is:pr"))
        #expect(query.contains("author:@me"))
    }

    @Test("a declaration exists for every variable")
    func declarationsMatchVariables() throws {
        let built = try #require(Queries.pullRequestsForIssueKeys(["A-1", "B-2"]))
        for name in built.variables.keys {
            #expect(built.query.contains("$\(name):"))
        }
    }

    /// A user with hundreds of assigned issues must not build a document
    /// GitHub refuses, so the caller chunks and this cap is what it chunks by.
    @Test("the alias cap is small enough to page under")
    func aliasCapIsSane() {
        #expect(Queries.issueKeyAliasCap > 0)
        #expect(Queries.issueKeyAliasCap <= 25)
    }

    @Test("more keys than the cap are refused rather than truncated silently")
    func overCapIsRefused() {
        let tooMany = (0..<(Queries.issueKeyAliasCap + 1)).map { "ACME-\($0)" }
        #expect(Queries.pullRequestsForIssueKeys(tooMany) == nil)
    }

    /// Duplicate keys would collide on alias index and double-count a row.
    @Test("duplicate keys are collapsed")
    func duplicatesCollapsed() throws {
        let built = try #require(Queries.pullRequestsForIssueKeys(["ACME-1", "ACME-1"]))
        #expect(built.variables.count == 1)
    }
}
