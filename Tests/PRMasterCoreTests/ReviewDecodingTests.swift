import Foundation
import Testing
@testable import PRMasterCore

private func team(_ slug: String) -> Team {
    Team(combinedSlug: "Lansweeper/\(slug)", organization: "Lansweeper", name: slug)
}

/// One search node, with only the parts a test varies spelled out.
private func node(
    id: String,
    number: Int = 909,
    repo: String = "Lansweeper/LECAIChatAssistant",
    isPrivate: Bool = true,
    author: String? = "pedrojcalvo",
    reviewDecision: String? = "REVIEW_REQUIRED",
    checks: String? = "SUCCESS",
    createdAt: String = "2026-08-20T10:00:00Z",
    updatedAt: String = "2026-08-21T10:00:00Z",
    additions: Int = 12,
    deletions: Int = 3,
    changedFiles: Int = 2
) -> String {
    let authorJSON = author.map { #"{"login":"\#($0)"}"# } ?? "null"
    let decisionJSON = reviewDecision.map { #""\#($0)""# } ?? "null"
    let rollup = checks.map { #"{"state":"\#($0)"}"# } ?? "null"
    return #"""
    {"id":"\#(id)","number":\#(number),"title":":bug: fix it",
     "url":"https://github.com/\#(repo)/pull/\#(number)",
     "headRefOid":"a408f981","createdAt":"\#(createdAt)","updatedAt":"\#(updatedAt)",
     "additions":\#(additions),"deletions":\#(deletions),"changedFiles":\#(changedFiles),
     "reviewDecision":\#(decisionJSON),"author":\#(authorJSON),
     "repository":{"nameWithOwner":"\#(repo)","isPrivate":\#(isPrivate)},
     "commits":{"nodes":[{"commit":{"statusCheckRollup":\#(rollup)}}]}}
    """#
}

private func search(count: Int, _ nodes: String...) -> String {
    #"{"issueCount":\#(count),"nodes":[\#(nodes.joined(separator: ","))]}"#
}

private func response(_ searches: String...) -> Data {
    let body = searches.enumerated()
        .map { #""s\#($0.offset)":\#($0.element)"# }
        .joined(separator: ",")
    return Data(#"{"data":{\#(body)}}"#.utf8)
}

@Suite("Review request decoding")
struct ReviewDecodingTests {

    // MARK: - Alias mapping

    @Test("each alias maps back to the team that produced it")
    func aliasesMapToTeams() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(
                search(count: 1, node(id: "PR_1")),
                search(count: 1, node(id: "PR_2"))
            ),
            teams: [team("asset-cortex"), team("datanauts")]
        )

        let byID = Dictionary(uniqueKeysWithValues: snapshot.requests.map { ($0.id, $0) })
        #expect(byID["PR_1"]?.teams.map(\.combinedSlug) == ["Lansweeper/asset-cortex"])
        #expect(byID["PR_2"]?.teams.map(\.combinedSlug) == ["Lansweeper/datanauts"])
    }

    @Test("the pending count is reported per team, rows or no rows")
    func countsPerTeam() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(
                search(count: 8, node(id: "PR_1")),
                // A disabled team: asked at first: 0, so a count and no nodes.
                search(count: 852)
            ),
            teams: [team("architecture-guild"), team("cloud-2")]
        )

        #expect(snapshot.pendingCounts["Lansweeper/architecture-guild"] == 8)
        #expect(snapshot.pendingCounts["Lansweeper/cloud-2"] == 852)
        #expect(snapshot.requests.count == 1)
    }

    // MARK: - Deduplication

    /// Seen live on Lansweeper/LEC-Honeycomb-tf 256, requested from both platform
    /// and datanauts. With one search per team the same pull request comes back
    /// under two aliases, and rendering it twice would be the visible bug.
    @Test("a pull request two of your teams were asked about is one row")
    func dedupesAcrossTeams() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(
                search(count: 1, node(id: "PR_1")),
                search(count: 1, node(id: "PR_1"))
            ),
            teams: [team("asset-cortex"), team("datanauts")]
        )

        #expect(snapshot.requests.count == 1)
        #expect(snapshot.requests[0].teams.map(\.combinedSlug) == [
            "Lansweeper/asset-cortex", "Lansweeper/datanauts",
        ])
    }

    /// The teams on a deduplicated row follow the order the teams arrived in,
    /// which is the sorted order `decodeTeams` produces — not the order the
    /// aliases happened to be read back in.
    @Test("the teams on a shared row keep the caller's order")
    func sharedRowTeamOrder() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(
                search(count: 1, node(id: "PR_1")),
                search(count: 1, node(id: "PR_1")),
                search(count: 1, node(id: "PR_1"))
            ),
            teams: [team("aardvark"), team("beetle"), team("cicada")]
        )

        #expect(snapshot.requests[0].teams.map(\.name) == ["aardvark", "beetle", "cicada"])
    }

    // MARK: - Ordering

    /// Flat and most-recently-active first, so the list does not depend on which
    /// team happened to be searched first.
    @Test("rows are ordered by last activity, newest first")
    func orderedByUpdatedAt() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(
                search(count: 2,
                       node(id: "PR_old", updatedAt: "2026-08-01T10:00:00Z"),
                       node(id: "PR_new", updatedAt: "2026-08-27T10:00:00Z")),
                search(count: 1, node(id: "PR_mid", updatedAt: "2026-08-15T10:00:00Z"))
            ),
            teams: [team("asset-cortex"), team("datanauts")]
        )

        #expect(snapshot.requests.map(\.id) == ["PR_new", "PR_mid", "PR_old"])
    }

    // MARK: - Absences

    /// An alias GitHub did not answer is omitted rather than recorded as zero
    /// pending. Not knowing is not the same as none, and a zero would tell the
    /// settings list that a team has nothing waiting.
    @Test("a missing alias is left out rather than counted as zero")
    func missingAliasIsOmitted() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            Data(#"{"data":{"s0":null}}"#.utf8),
            teams: [team("asset-cortex")]
        )

        #expect(snapshot.requests.isEmpty)
        #expect(snapshot.pendingCounts["Lansweeper/asset-cortex"] == nil)
    }

    @Test("the diff's size reaches the row, so the remark has something to read")
    func diffSizeIsDecoded() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(
                search(count: 1, node(id: "PR_1", additions: 8, deletions: 941, changedFiles: 63))
            ),
            teams: [team("asset-cortex")]
        )

        let row = try #require(snapshot.requests.first)
        #expect(row.additions == 8)
        #expect(row.deletions == 941)
        #expect(row.changedFiles == 63)
    }

    @Test("a team with nothing pending reports zero rather than nothing")
    func genuineZeroIsRecorded() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(search(count: 0)),
            teams: [team("database-architects")]
        )

        #expect(snapshot.pendingCounts["Lansweeper/database-architects"] == 0)
    }

    /// GitHub reassigns a deleted account's pull requests to nobody, so `author`
    /// is nullable. The pull request is still real and still needs reviewing, so
    /// the row survives — it just cannot name who opened it.
    @Test("a deleted author does not lose the row")
    func deletedAuthorSurvives() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(search(count: 1, node(id: "PR_1", author: nil))),
            teams: [team("asset-cortex")]
        )

        #expect(snapshot.requests.count == 1)
        #expect(snapshot.requests[0].author == "ghost")
    }

    @Test("a repository with no CI decodes as no checks rather than pending")
    func absentRollup() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(search(count: 1, node(id: "PR_1", checks: nil))),
            teams: [team("asset-cortex")]
        )

        #expect(snapshot.requests[0].checks == nil)
        #expect(snapshot.requests[0].state == .awaiting)
    }

    @Test("a repository requiring no review decodes as no decision")
    func absentReviewDecision() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(search(count: 1, node(id: "PR_1", reviewDecision: nil))),
            teams: [team("asset-cortex")]
        )

        #expect(snapshot.requests[0].reviewDecision == nil)
    }

    // MARK: - Field mapping

    @Test("the nested wire shape collapses onto the flat model")
    func flattensNesting() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(search(count: 1, node(
                id: "PR_kwDONwH6ds8AAAABBDNO4w",
                number: 187,
                repo: "Lansweeper/architecture-decisions",
                isPrivate: true,
                author: "jeroensavat",
                reviewDecision: "CHANGES_REQUESTED",
                checks: "FAILURE"
            ))),
            teams: [team("architecture-guild")]
        )

        let request = try #require(snapshot.requests.first)
        #expect(request.id == "PR_kwDONwH6ds8AAAABBDNO4w")
        #expect(request.number == 187)
        #expect(request.repo == "Lansweeper/architecture-decisions")
        #expect(request.organization == "Lansweeper")
        #expect(request.isPrivate)
        #expect(request.author == "jeroensavat")
        #expect(request.headRefOid == "a408f981")
        #expect(request.reviewDecision == .changesRequested)
        #expect(request.checks == .failure)
        // Changes requested outranks the failing checks.
        #expect(request.state == .changesRequested)
        #expect(request.displayTitle == "🐛 fix it")
    }

    @Test("timestamps parse as ISO8601")
    func parsesDates() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(search(count: 1, node(
                id: "PR_1",
                createdAt: "2026-08-26T08:50:26Z",
                updatedAt: "2026-08-26T09:10:06Z"
            ))),
            teams: [team("asset-cortex")]
        )

        let request = try #require(snapshot.requests.first)
        #expect(request.createdAt == Date(timeIntervalSince1970: 1_787_734_226))
        #expect(request.updatedAt == Date(timeIntervalSince1970: 1_787_735_406))
    }

    /// An enum value GitHub adds later must not blank the section, and the
    /// fallback has to be the pessimistic one — the rule `UnknownTolerantEnum`
    /// documents. A rollup this app cannot read is checks running, never passing.
    @Test("an unrecognised check state degrades to pending, never to success")
    func unknownCheckStateIsPending() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(search(count: 1, node(id: "PR_1", checks: "SOMETHING_NEW"))),
            teams: [team("asset-cortex")]
        )

        #expect(snapshot.requests[0].checks == .pending)
        #expect(snapshot.requests[0].state == .checksPending)
    }

    @Test("an unrecognised review decision assumes a review is still needed")
    func unknownDecisionAssumesReviewRequired() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            response(search(count: 1, node(id: "PR_1", reviewDecision: "SOMETHING_NEW"))),
            teams: [team("asset-cortex")]
        )

        #expect(snapshot.requests[0].reviewDecision == .reviewRequired)
    }

    // MARK: - Failure

    /// The same rule every other decoder here follows: GitHub reports a SAML SSO
    /// refusal as a 200 with a null payload, and reading that as an empty section
    /// would say nothing is waiting on any of your teams.
    @Test("errors in a 200 response surface as graphQL, not as an empty section")
    func errorsSurface() throws {
        let data = Data(
            #"{"data":null,"errors":[{"message":"Although you appear to have the correct authorization credentials"}]}"#
                .utf8
        )

        do {
            _ = try PullRequestDecoder.decodeReviewRequests(data, teams: [team("asset-cortex")])
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .graphQL = error else {
                Issue.record("expected .graphQL, got \(error)")
                return
            }
        }
    }

    @Test("a body with neither data nor errors throws")
    func neitherDataNorErrors() throws {
        do {
            _ = try PullRequestDecoder.decodeReviewRequests(
                Data("{}".utf8), teams: [team("asset-cortex")]
            )
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test("no teams decodes to an empty snapshot")
    func noTeams() throws {
        let snapshot = try PullRequestDecoder.decodeReviewRequests(
            Data(#"{"data":{}}"#.utf8), teams: []
        )

        #expect(snapshot.requests.isEmpty)
        #expect(snapshot.pendingCounts.isEmpty)
    }
}
