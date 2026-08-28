import Foundation
import Testing
@testable import PRMasterCore

private func team(_ slug: String) -> Team {
    Team(combinedSlug: "Lansweeper/\(slug)", organization: "Lansweeper", name: slug)
}

private let allTeams = [team("asset-cortex"), team("cloud-2"), team("datanauts")]

private func build(
    teams: [Team] = allTeams,
    disabled: Set<String> = [],
    window: ReviewWindow = .twoWeeks
) -> (query: String, variables: [String: GraphQLValue])? {
    Queries.reviewRequests(
        for: teams,
        filter: TeamFilter(disabledTeams: disabled),
        window: window,
        now: Date(timeIntervalSince1970: 1_786_692_165)
    )
}

@Suite("Review request query")
struct ReviewQueryTests {

    // MARK: - Shape

    /// One search per team rather than one search OR-ing every team together,
    /// though repeating the qualifier does OR. A single search would need a
    /// single cap, and on the account this was built for that lets one team with
    /// 852 pending bury another with 8.
    @Test("each team gets its own aliased search")
    func aliasPerTeam() throws {
        let built = try #require(build())

        #expect(built.query.contains("s0: search("))
        #expect(built.query.contains("s1: search("))
        #expect(built.query.contains("s2: search("))
        #expect(built.query.contains("s3: search(") == false)
    }

    /// The alias order is the contract `decodeReviewRequests` maps back by, so it
    /// has to follow the array it was given.
    @Test("aliases are assigned in the order the teams arrive")
    func aliasesFollowTeamOrder() throws {
        let built = try #require(build())

        #expect(built.variables["q0"] == .string(searchString(for: "asset-cortex")))
        #expect(built.variables["q1"] == .string(searchString(for: "cloud-2")))
        #expect(built.variables["q2"] == .string(searchString(for: "datanauts")))
    }

    /// The count is what makes a switched-off team's row in settings say what
    /// enabling it would cost, so it is selected for every team.
    @Test("every search reports how many are pending")
    func issueCountIsSelected() throws {
        let built = try #require(build())
        #expect(built.query.contains("issueCount"))
    }

    // MARK: - Enabled and disabled

    /// A disabled team is still asked, at `first: 0`. GitHub answers `issueCount`
    /// regardless of the page size, so the settings list can offer a real number
    /// for a team the user has switched off without fetching one row of it.
    @Test("a disabled team is asked for a count and no rows")
    func disabledTeamCostsNoRows() throws {
        let built = try #require(build(disabled: ["Lansweeper/cloud-2"]))

        #expect(built.variables["n0"] == .int(Queries.reviewRequestPageSize))
        #expect(built.variables["n1"] == .int(0))
        #expect(built.variables["n2"] == .int(Queries.reviewRequestPageSize))
    }

    @Test("every team enabled asks for rows from all of them")
    func allEnabled() throws {
        let built = try #require(build())

        for index in 0..<allTeams.count {
            #expect(built.variables["n\(index)"] == .int(Queries.reviewRequestPageSize))
        }
    }

    /// Still one request, and still worth sending: the counts are what the
    /// settings tab is built out of, and without them every team would read as
    /// having nothing pending.
    @Test("every team disabled still asks for the counts")
    func allDisabledStillCounts() throws {
        let built = try #require(build(disabled: Set(allTeams.map(\.combinedSlug))))

        #expect(built.query.contains("s0: search("))
        for index in 0..<allTeams.count {
            #expect(built.variables["n\(index)"] == .int(0))
        }
    }

    // MARK: - The search string

    @Test("the search asks for exactly what this section is")
    func searchQualifiers() throws {
        let built = try #require(build())
        let query = try #require(built.variables["q0"])
        guard case .string(let search) = query else {
            Issue.record("expected a string variable")
            return
        }

        #expect(search.contains("is:pr"))
        #expect(search.contains("is:open"))
        #expect(search.contains("archived:false"))
        // A draft is not waiting for anybody's approval.
        #expect(search.contains("draft:false"))
        #expect(search.contains("team-review-requested:Lansweeper/asset-cortex"))
        #expect(search.contains("sort:updated-desc"))
    }

    /// Required rather than tidy: GitHub refuses to let anybody approve their own
    /// pull request, so without this the section would offer an Approve button
    /// that cannot work — on rows already listed in the section above.
    @Test("your own pull requests are excluded")
    func excludesOwnPullRequests() throws {
        let built = try #require(build())
        #expect(searchText(built, "q0").contains("-author:@me"))
    }

    /// Already reviewed is not pending your approval. Without this a row you had
    /// dealt with would sit there until somebody else cleared the team request.
    @Test("pull requests you have already reviewed are excluded")
    func excludesAlreadyReviewed() throws {
        let built = try #require(build())
        #expect(searchText(built, "q0").contains("-reviewed-by:@me"))
    }

    /// The age limit rides in the search rather than being applied afterwards,
    /// which is what keeps the request itself small — 1846 pending against 76.
    @Test("the age limit is part of the search, not applied after it")
    func windowIsInTheSearch() throws {
        let built = try #require(build(window: .twoWeeks))
        let search = searchText(built, "q0")

        #expect(search.contains("created:>"))
        // Full timestamp, never a bare date — see ReviewWindow.createdQualifier.
        #expect(search.contains("T"))
        #expect(search.contains("Z"))
    }

    // MARK: - Nothing to ask

    @Test("off asks nothing at all")
    func offSendsNoRequest() {
        #expect(build(window: .off) == nil)
    }

    @Test("no teams asks nothing at all")
    func noTeamsSendsNoRequest() {
        #expect(build(teams: []) == nil)
    }

    // MARK: - Injection

    /// The rule `Queries.containment` establishes: generated aliases and
    /// generated variable *names* only. A team slug is remote data, and the one
    /// place it may appear is a variable value.
    @Test("no team slug reaches the document text")
    func slugsRideAsVariables() throws {
        let built = try #require(build())

        #expect(built.query.contains("asset-cortex") == false)
        #expect(built.query.contains("cloud-2") == false)
        #expect(built.query.contains("Lansweeper") == false)
        #expect(built.query.contains("$q0: String!"))
        #expect(built.query.contains("$n0: Int!"))
    }

    /// A team whose slug carried GraphQL syntax could not break out of a variable
    /// value, and this proves the value is passed through untouched rather than
    /// escaped or rejected on the way.
    @Test("a hostile slug survives as a value and never as syntax")
    func hostileSlugStaysAValue() throws {
        let hostile = Team(
            combinedSlug: #"acme/") { evil } #"#, organization: "acme", name: "evil"
        )
        let built = try #require(build(teams: [hostile]))

        #expect(built.query.contains("evil") == false)
        #expect(searchText(built, "q0").contains(#"team-review-requested:acme/") { evil } #"#))
    }

    // MARK: - Selection the decoder depends on

    @Test("the fields the row and the decoder need are all selected")
    func selectsEveryFieldNeeded() throws {
        let built = try #require(build())

        for field in [
            "id", "number", "title", "url", "headRefOid", "createdAt", "updatedAt",
            "reviewDecision", "author", "login", "nameWithOwner", "isPrivate",
            "statusCheckRollup",
        ] {
            #expect(built.query.contains(field), "missing \(field)")
        }
    }

    // MARK: - Helpers

    private func searchText(
        _ built: (query: String, variables: [String: GraphQLValue]), _ key: String
    ) -> String {
        guard case .string(let search)? = built.variables[key] else { return "" }
        return search
    }

    private func searchString(for slug: String) -> String {
        let window = ReviewWindow.twoWeeks
        let created = window.createdQualifier(now: Date(timeIntervalSince1970: 1_786_692_165))!
        return "is:pr is:open archived:false draft:false "
            + "team-review-requested:Lansweeper/\(slug) -author:@me -reviewed-by:@me "
            + "\(created) sort:updated-desc"
    }
}
