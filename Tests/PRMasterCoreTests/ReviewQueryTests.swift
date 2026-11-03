import Foundation
import Testing
@testable import PRMasterCore

private func team(_ slug: String) -> Team {
    Team(combinedSlug: "Lansweeper/\(slug)", organization: "Lansweeper", name: slug)
}

private let allTeams = [team("asset-cortex"), team("cloud-2"), team("datanauts")]

private func requests(
    teams: [Team] = allTeams,
    disabled: Set<String> = [],
    window: ReviewWindow = .twoWeeks
) -> [(query: String, variables: [String: GraphQLValue])] {
    Queries.reviewRequests(
        for: teams,
        filter: TeamFilter(disabledTeams: disabled),
        window: window,
        now: Date(timeIntervalSince1970: 1_786_692_165)
    )
}

/// Every request's text and variables together, for the tests about what is asked rather than how it is split.
private func build(
    teams: [Team] = allTeams,
    disabled: Set<String> = [],
    window: ReviewWindow = .twoWeeks
) -> (query: String, variables: [String: GraphQLValue])? {
    let all = requests(teams: teams, disabled: disabled, window: window)
    guard !all.isEmpty else { return nil }
    return (
        all.map(\.query).joined(separator: "\n"),
        all.reduce(into: [:]) { merged, request in merged.merge(request.variables) { first, _ in first } }
    )
}

private func searchCount(_ query: String) -> Int {
    query.components(separatedBy: ": search(").count - 1
}

private func fetchesRows(_ request: (query: String, variables: [String: GraphQLValue])) -> Bool {
    request.variables.values.contains(.int(Queries.reviewRequestPageSize))
}

private let manyTeams = (0..<14).map { team("team-\($0)") }

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

    // MARK: - The dismissal search

    /// Measured on Lansweeper/assetcortex-deployments 1213: a dismissal does not
    /// restore the team request, so no per-team search can bring the row back.
    @Test("one more search covers the reviews that stopped counting")
    func dismissalSearchIsSent() throws {
        let built = try #require(build())

        #expect(built.query.contains("d: search("))
        #expect(built.variables["qd"] == .string(dismissalSearchString()))
    }

    /// `reviewed-by:@me` alone also matches a review that still stands, and
    /// `review:none` alone matches a pull request nobody has touched.
    @Test("the dismissal search narrows to reviews that no longer count")
    func dismissalQualifiers() throws {
        let built = try #require(build())
        let search = searchText(built, "qd")

        #expect(search.contains("reviewed-by:@me"))
        #expect(search.contains("-reviewed-by:@me") == false)
        #expect(search.contains("review:none"))
        #expect(search.contains("team-review-requested:") == false)
    }

    @Test("the dismissal search keeps the section's own limits")
    func dismissalKeepsSectionLimits() throws {
        let built = try #require(build())
        let search = searchText(built, "qd")

        for qualifier in [
            "is:pr", "is:open", "archived:false", "draft:false", "-author:@me",
            "created:>", "sort:updated-desc",
        ] {
            #expect(search.contains(qualifier), "missing \(qualifier)")
        }
    }

    /// The team request is gone by the time a review is dismissed, so the
    /// timeline is the only remaining record of which team was asked.
    @Test("the dismissal search selects what attributes a row to a team")
    func dismissalSelectsAttribution() throws {
        let built = try #require(build())

        #expect(built.query.contains("viewerLatestReview"))
        #expect(built.query.contains("REVIEW_REQUESTED_EVENT"))
        #expect(built.query.contains("combinedSlug"))
    }

    @Test("no enabled team means the dismissal search fetches no rows")
    func dismissalFetchesNothingWithNoEnabledTeam() throws {
        let built = try #require(build(disabled: Set(allTeams.map(\.combinedSlug))))
        #expect(built.variables["nd"] == .int(0))
        let partly = try #require(build(disabled: ["Lansweeper/cloud-2"]))
        #expect(partly.variables["nd"] == .int(Queries.reviewRequestPageSize))
    }

    // MARK: - Asked of you by name

    /// Lansweeper/LECAnalyticsAssetsConsumerV2 836: the author re-requested the
    /// user after their review, and no team search could see it.
    @Test("one more search covers the pull requests asked of you by name")
    func personalSearchIsSent() throws {
        let built = try #require(build())

        #expect(built.query.contains("p: search("))
        #expect(built.variables["qp"] == .string(personalSearchString()))
    }

    /// GitHub removes your request when you review, so one standing is a request
    /// to look again rather than one you have dealt with.
    @Test("the personal search keeps what you have already reviewed")
    func personalSearchKeepsReviewed() throws {
        let built = try #require(build())
        let search = searchText(built, "qp")

        #expect(search.contains("user-review-requested:@me"))
        #expect(search.contains("reviewed-by:@me") == false)
        #expect(search.contains("team-review-requested:") == false)
    }

    @Test("the personal search keeps the section's own limits")
    func personalKeepsSectionLimits() throws {
        let search = searchText(try #require(build()), "qp")

        for qualifier in [
            "is:pr", "is:open", "archived:false", "draft:false", "-author:@me",
            "created:>", "sort:updated-desc",
        ] {
            #expect(search.contains(qualifier), "missing \(qualifier)")
        }
    }

    /// The team switches say which teams to hear from, not whether to hear from you.
    @Test("switching every team off still fetches what was asked of you")
    func personalIgnoresTeamFilter() throws {
        let built = try #require(build(disabled: Set(allTeams.map(\.combinedSlug))))
        #expect(built.variables["np"] == .int(Queries.reviewRequestPageSize))
    }

    @Test("belonging to no teams still asks what was asked of you, and nothing else")
    func noTeamsAsksOnlyPersonal() throws {
        let all = requests(teams: [])

        #expect(all.count == 1)
        #expect(all.first.map { searchCount($0.query) } == 1)
        #expect(all.first?.query.contains("p: search(") == true)
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
            "statusCheckRollup", "additions", "deletions", "changedFiles",
        ] {
            #expect(built.query.contains(field), "missing \(field)")
        }
    }

    // MARK: - Under GitHub's ten-second cutoff

    /// Measured 2026-10-29: Datanauts' 20 rows took up to 7.1 s alone, and every
    /// search in one request took 10 s, past the cutoff GitHub answers with a 502.
    @Test("a search that fetches rows is the only search in its request")
    func rowSearchesTravelAlone() {
        let all = requests(disabled: ["Lansweeper/cloud-2"])
        let withRows = all.filter(fetchesRows)

        #expect(withRows.count == 4)
        #expect(withRows.allSatisfy { searchCount($0.query) == 1 })
    }

    @Test("count-only searches share requests, a few at a time")
    func countSearchesAreGrouped() {
        let all = requests(teams: manyTeams, disabled: Set(manyTeams.map(\.combinedSlug)))

        #expect(all.filter { !fetchesRows($0) }.count == 3)
        #expect(all.allSatisfy { searchCount($0.query) <= Queries.countSearchesPerRequest })
    }

    @Test("every search is asked exactly once across the requests")
    func everySearchAskedOnce() {
        let all = requests(teams: manyTeams, disabled: ["Lansweeper/team-3", "Lansweeper/team-9"])
        let searches = all.flatMap { $0.variables.keys.filter { $0.hasPrefix("q") } }

        #expect(searches.count == Set(searches).count)
        #expect(Set(searches) == Set(manyTeams.indices.map { "q\($0)" } + ["qd", "qp"]))
        #expect(all.map { searchCount($0.query) }.reduce(0, +) == manyTeams.count + 2)
    }

    /// GitHub refuses a document whose declared variables and supplied values disagree.
    @Test("each request carries exactly the variables it declares")
    func variablesMatchDeclarations() {
        for request in requests(teams: manyTeams, disabled: ["Lansweeper/team-3"]) {
            for name in request.variables.keys {
                #expect(request.query.contains("$\(name): "), "\(name) supplied but not declared")
            }
            let declarationsAndUses = request.query.components(separatedBy: "$").count - 1
            #expect(declarationsAndUses == request.variables.count * 2)
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

    private func personalSearchString() -> String {
        let window = ReviewWindow.twoWeeks
        let created = window.createdQualifier(now: Date(timeIntervalSince1970: 1_786_692_165))!
        return "is:pr is:open archived:false draft:false "
            + "user-review-requested:@me -author:@me "
            + "\(created) sort:updated-desc"
    }

    private func dismissalSearchString() -> String {
        let window = ReviewWindow.twoWeeks
        let created = window.createdQualifier(now: Date(timeIntervalSince1970: 1_786_692_165))!
        return "is:pr is:open archived:false draft:false "
            + "-author:@me reviewed-by:@me review:none "
            + "\(created) sort:updated-desc"
    }
}
