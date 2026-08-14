import Foundation
import Testing
@testable import PRMasterCore

private func candidate(
    prID: String,
    repo: String,
    oid: String,
    tag: String
) -> ContainmentCandidate {
    ContainmentCandidate(
        pullRequest: MergedPullRequest(
            id: prID,
            number: 1,
            title: "t",
            url: URL(string: "https://github.com/\(repo)/pull/1")!,
            repo: repo,
            repositoryID: "R_\(repo)",
            isPrivate: false,
            mergedAt: Date(timeIntervalSince1970: 1_000),
            mergeCommitOid: oid,
            rollupState: .success,
            contexts: []
        ),
        release: Release(
            tagName: tag,
            url: URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!,
            tagCommitOid: "0eea2bd0",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
    )
}

@Suite("Queries")
struct QueriesTests {

    // MARK: the built query

    @Test("candidates across two repositories each get their own alias")
    func uniqueAliasesAcrossRepositories() throws {
        let built = try #require(Queries.containment(for: [
            candidate(prID: "PR_1", repo: "acme/widget-service", oid: "aaa", tag: "v1.226.0"),
            candidate(prID: "PR_2", repo: "acme/chat-assistant", oid: "bbb", tag: "v3.31.2"),
        ]))

        #expect(built.query.contains("t0: repository("))
        #expect(built.query.contains("t1: repository("))
    }

    /// `v3.31.2` is not a legal GraphQL alias — the dots end the name. That is
    /// the whole reason aliases are generated rather than taken from the tag.
    @Test("a tag name becomes a generated alias and survives as a variable value")
    func tagBecomesAliasAndSurvivesAsValue() throws {
        let built = try #require(Queries.containment(for: [
            candidate(prID: "PR_1", repo: "acme/widget-service", oid: "aaa", tag: "v3.31.2"),
        ]))

        #expect(built.query.contains("t0: repository("))
        // The tag itself is untouched where it counts: in the variable value.
        #expect(built.variables["tag0"] == "refs/tags/v3.31.2")
    }

    /// The one query in this app built from data GitHub sent us. Only aliases
    /// and variable names are generated; if a remote string ever reaches the
    /// document text, escaping becomes this app's problem — and it should not be.
    @Test("no remote value appears anywhere in the document text")
    func noRemoteValueInDocument() throws {
        let built = try #require(Queries.containment(for: [
            candidate(prID: "PR_1", repo: "acme/widget-service", oid: "deadbeef", tag: "v3.31.2"),
        ]))

        #expect(built.query.contains("v3.31.2") == false)
        #expect(built.query.contains("deadbeef") == false)
        #expect(built.query.contains("acme") == false)
        #expect(built.query.contains("widget-service") == false)
    }

    /// A declared variable with nothing bound to it is a query GitHub rejects
    /// outright, and every value present is what makes the escaping argument
    /// above hold.
    @Test("every declared variable has a value bound to it")
    func declaredVariablesAreAllBound() throws {
        let built = try #require(Queries.containment(for: [
            candidate(prID: "PR_1", repo: "acme/widget-service", oid: "aaa", tag: "v1.226.0"),
            candidate(prID: "PR_2", repo: "acme/chat-assistant", oid: "bbb", tag: "v3.31.2"),
        ]))

        let declared = Set(
            built.query
                .split(whereSeparator: { " (,:)\n".contains($0) })
                .filter { $0.hasPrefix("$") }
                .map { String($0.dropFirst()) }
        )

        #expect(declared.isEmpty == false)
        #expect(declared == Set(built.variables.keys))
    }

    @Test("the owner and name of a repository are split apart correctly")
    func splitsOwnerAndName() throws {
        let built = try #require(Queries.containment(for: [
            candidate(prID: "PR_1", repo: "acme/widget-service", oid: "aaa", tag: "v1.0.0"),
        ]))
        #expect(built.variables["owner0"] == "acme")
        #expect(built.variables["name0"] == "widget-service")
        #expect(built.variables["oid0"] == "aaa")
    }

    /// Nothing to ask about means no request at all, not an empty document that
    /// GitHub would reject.
    @Test("no candidates yields no query")
    func noCandidatesNoQuery() {
        #expect(Queries.containment(for: []) == nil)
    }

    // MARK: the constant queries

    @Test("the search asks for both halves in one document")
    func searchCarriesBothHalves() {
        #expect(Queries.myPullRequests.contains("open: search("))
        #expect(Queries.myPullRequests.contains("merged: search("))
        // The merged half's window moves, so it rides as a variable rather than
        // being pasted into the document on every poll.
        #expect(Queries.myPullRequests.contains("$mergedQuery: String!"))
        #expect(Queries.myPullRequests.contains("mergeCommit"))
        #expect(Queries.myPullRequests.contains("statusCheckRollup"))
    }

    @Test("the releases query takes repository node IDs as one variable")
    func releasesTakesNodeIDs() {
        #expect(Queries.releases.contains("$repoIds: [ID!]!"))
        #expect(Queries.releases.contains("nodes(ids: $repoIds)"))
        #expect(Queries.releases.contains("tagCommit"))
    }
}
