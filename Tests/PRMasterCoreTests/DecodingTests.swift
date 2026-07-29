import Foundation
import Testing
@testable import PRMasterCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture \(name).json"
    )
    return try Data(contentsOf: url)
}

@Suite("GraphQL decoding")
struct DecodingTests {

    // MARK: happy path

    @Test("decodes every node in a search response")
    func decodesAllNodes() throws {
        let prs = try PullRequestDecoder.decodeSearch(try fixture("search-response"))
        #expect(prs.count == 4)
    }

    @Test("flattens the nested GraphQL shape onto the domain model")
    func flattensNesting() throws {
        let pr = try #require(
            try PullRequestDecoder.decodeSearch(try fixture("search-response")).first
        )
        #expect(pr.id == "PR_kwDOAAAAAA71xzWs")
        #expect(pr.number == 1204)
        #expect(pr.title == "paginate the widget catalogue endpoint")
        // repository { nameWithOwner } collapses to a flat string
        #expect(pr.repo == "acme/widget-service")
        // commits.nodes[0].commit.statusCheckRollup.state collapses too
        #expect(pr.checks == .success)
        #expect(pr.approvals == 2)
        #expect(pr.mergeState == .clean)
        #expect(pr.reviewDecision == .approved)
        #expect(pr.headRefOid == "52eca0e32d7c8511105b13f5a7bb497246e84a1f")
        #expect(pr.readiness == .ready)
    }

    @Test("parses ISO8601 timestamps")
    func parsesDates() throws {
        let pr = try #require(
            try PullRequestDecoder.decodeSearch(try fixture("search-response")).first
        )
        // 2026-07-27T08:56:15Z
        #expect(pr.updatedAt == Date(timeIntervalSince1970: 1785142575))
    }

    @Test("carries the draft flag through")
    func decodesDraft() throws {
        let prs = try PullRequestDecoder.decodeSearch(try fixture("search-response"))
        #expect(prs[3].isDraft)
        #expect(prs[3].readiness == .draft)
    }

    /// `repository { isPrivate }` is what the settings window filters on, and it
    /// arrives one level down from where the model keeps it.
    @Test("carries the private flag through")
    func decodesPrivate() throws {
        let prs = try PullRequestDecoder.decodeSearch(try fixture("search-response"))
        #expect(prs[1].isPrivate, "acme/chat-assistant is the private one")
        #expect(prs[0].isPrivate == false)
    }

    // MARK: the traps

    /// A repo with no CI reports `statusCheckRollup: null`. Decoding that as
    /// pending rather than nil would leave the PR permanently unready.
    @Test("a null check rollup decodes to nil, not pending")
    func nullRollupIsNil() throws {
        let prs = try PullRequestDecoder.decodeSearch(try fixture("search-response"))
        let noCI = try #require(prs.first { $0.repo == "acme/docs-site" })
        #expect(noCI.checks == nil)
        #expect(noCI.checks != .pending)
        #expect(noCI.readiness == .ready)
    }

    @Test("a null review decision stays nil")
    func nullReviewDecision() throws {
        let prs = try PullRequestDecoder.decodeSearch(try fixture("search-response"))
        let blocked = try #require(prs.first { $0.repo == "acme/chat-assistant" })
        #expect(blocked.reviewDecision == nil)
        // The blocked-but-mergeable trap: no review required, mergeable, yet blocked.
        #expect(blocked.mergeable == .mergeable)
        #expect(blocked.readiness == .blocked)
    }

    /// GitHub adds enum cases over time. Strict decoding would throw and blank
    /// the entire list because of one unfamiliar string.
    @Test("unknown enum values fall back instead of throwing")
    func unknownEnumsFallBack() throws {
        let prs = try PullRequestDecoder.decodeSearch(try fixture("unknown-enums"))
        let pr = try #require(prs.first)
        #expect(pr.mergeable == .unknown)
        #expect(pr.mergeState == .unknown)
        #expect(pr.reviewDecision == .reviewRequired)
        // An unrecognised check state must never read as success.
        #expect(pr.checks == .pending)
        #expect(pr.readiness != .ready)
    }

    /// GitHub returns SAML SSO failures as HTTP 200 with an errors array, so a
    /// status-code-only check would silently show an empty PR list.
    @Test("errors in a 200 response surface as graphQL, not an empty list")
    func errorsInSuccessfulResponse() throws {
        let data = try fixture("graphql-errors")
        #expect(throws: PRMasterError.self) {
            _ = try PullRequestDecoder.decodeSearch(data)
        }
        do {
            _ = try PullRequestDecoder.decodeSearch(data)
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .graphQL(let messages) = error else {
                Issue.record("expected .graphQL, got \(error)")
                return
            }
            #expect(messages.count == 2)
            #expect(messages[0].contains("SAML"))
        }
    }

    @Test("malformed JSON surfaces as a decoding error")
    func malformedJSON() throws {
        #expect(throws: PRMasterError.self) {
            _ = try PullRequestDecoder.decodeSearch(Data("{ not json".utf8))
        }
    }
}
