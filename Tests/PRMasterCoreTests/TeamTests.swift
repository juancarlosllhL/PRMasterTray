import Foundation
import Testing
@testable import PRMasterCore

/// One organization node, with whichever role lists the caller wants.
private func organization(
    login: String, member: [(String, String)] = [], admin: [(String, String)] = []
) -> String {
    func list(_ teams: [(String, String)]) -> String {
        let nodes = teams
            .map { #"{"name":"\#($0.0)","combinedSlug":"\#($0.1)"}"# }
            .joined(separator: ",")
        return #"{"nodes":[\#(nodes)]}"#
    }
    return #"""
    {"login":"\#(login)","member":\#(list(member)),"admin":\#(list(admin))}
    """#
}

private func response(_ organizations: String...) -> Data {
    Data(
        #"{"data":{"viewer":{"organizations":{"nodes":[\#(organizations.joined(separator: ","))]}}}}"#
            .utf8
    )
}

@Suite("Teams")
struct TeamTests {

    // MARK: - The query

    /// The one assertion here that is a correctness matter rather than a
    /// description of the code.
    ///
    /// `role` on `Organization.teams` is *viewer*-relative, and GitHub's
    /// `TeamRole` has exactly two cases: a plain member is `MEMBER` and a team
    /// maintainer is `ADMIN`. Asking only for `MEMBER` therefore drops every team
    /// the user maintains, silently and with no error — verified against a real
    /// account where `MEMBER` answered nine teams and `ADMIN` answered none, so
    /// the bug would have stayed invisible until somebody was promoted.
    @Test("both viewer roles are asked for, because one of them is not enough")
    func asksForBothRoles() {
        #expect(Queries.myTeams.contains("member: teams("))
        #expect(Queries.myTeams.contains("admin: teams("))
        #expect(Queries.myTeams.contains("role: MEMBER"))
        #expect(Queries.myTeams.contains("role: ADMIN"))
    }

    @Test("the query asks for the slug the search qualifier actually takes")
    func asksForCombinedSlug() {
        // `team-review-requested:` takes `Org/team-slug`, which is exactly what
        // `combinedSlug` is. Deriving it from name would not survive a rename.
        #expect(Queries.myTeams.contains("combinedSlug"))
    }

    // MARK: - Decoding

    @Test("teams from both roles end up in one list")
    func unionsBothRoles() throws {
        let teams = try PullRequestDecoder.decodeTeams(response(organization(
            login: "Lansweeper",
            member: [("Cloud 2", "Lansweeper/cloud-2")],
            admin: [("Datanauts", "Lansweeper/datanauts")]
        )))

        #expect(teams.map(\.combinedSlug) == ["Lansweeper/cloud-2", "Lansweeper/datanauts"])
    }

    /// Nothing documents the two role lists as disjoint, and the same team in
    /// both would otherwise be searched twice and listed twice in settings.
    @Test("a team in both role lists appears once")
    func dedupesAcrossRoles() throws {
        let teams = try PullRequestDecoder.decodeTeams(response(organization(
            login: "Lansweeper",
            member: [("Cloud 2", "Lansweeper/cloud-2")],
            admin: [("Cloud 2", "Lansweeper/cloud-2")]
        )))

        #expect(teams.count == 1)
    }

    @Test("teams are collected across every organization")
    func spansOrganizations() throws {
        let teams = try PullRequestDecoder.decodeTeams(response(
            organization(login: "Lansweeper", member: [("Cloud 2", "Lansweeper/cloud-2")]),
            organization(login: "acme", member: [("Widgets", "acme/widgets")])
        ))

        #expect(teams.count == 2)
    }

    /// The organization is taken from the node that answered rather than split
    /// off the slug: the login is the authoritative spelling, and the slug is
    /// only conventionally built from it.
    @Test("the organization comes from the node that answered")
    func organizationFromLogin() throws {
        let team = try #require(
            try PullRequestDecoder.decodeTeams(response(organization(
                login: "Lansweeper", member: [("Asset Cortex", "Lansweeper/asset-cortex")]
            ))).first
        )

        #expect(team.organization == "Lansweeper")
        #expect(team.name == "Asset Cortex")
        #expect(team.id == "Lansweeper/asset-cortex")
    }

    /// The settings list reads in this order and the search aliases are assigned
    /// in it, so it has to be stable rather than whatever GitHub returned.
    @Test("teams come back sorted by slug")
    func sorted() throws {
        let teams = try PullRequestDecoder.decodeTeams(response(organization(
            login: "Lansweeper",
            member: [
                ("Node Maintainers", "Lansweeper/node-maintainers"),
                ("Asset Cortex", "Lansweeper/asset-cortex"),
            ],
            admin: [("Cloud 2", "Lansweeper/cloud-2")]
        )))

        #expect(teams.map(\.combinedSlug) == [
            "Lansweeper/asset-cortex", "Lansweeper/cloud-2", "Lansweeper/node-maintainers",
        ])
    }

    /// One organization GitHub declines to resolve must not take the other
    /// organizations' teams down with it — the rule `ReleasesPayload` follows for
    /// a repository deleted between two calls.
    @Test("a null organization node does not lose the others")
    func nullOrganizationTolerated() throws {
        let data = Data(
            #"""
            {"data":{"viewer":{"organizations":{"nodes":[null,\#(organization(
                login: "Lansweeper", member: [("Cloud 2", "Lansweeper/cloud-2")]
            ))]}}}}
            """#.utf8
        )

        #expect(try PullRequestDecoder.decodeTeams(data).count == 1)
    }

    /// Being in no teams is a real answer, not a failure. The section simply has
    /// nothing to list.
    @Test("no teams decodes to an empty list rather than throwing")
    func noTeamsIsNotAnError() throws {
        #expect(try PullRequestDecoder.decodeTeams(response()).isEmpty)
    }

    // MARK: - Failure

    /// GitHub reports a SAML SSO refusal, and a missing `read:org` scope, as a
    /// 200 carrying an errors array. Reading that as an empty list would tell the
    /// user they are in no teams, which is the one wrong answer here: they would
    /// have no reason to go and fix the scope.
    @Test("errors in a 200 response surface as graphQL, not as no teams")
    func errorsSurface() throws {
        let data = Data(
            #"{"data":null,"errors":[{"message":"Resource not accessible by integration"}]}"#.utf8
        )

        do {
            _ = try PullRequestDecoder.decodeTeams(data)
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .graphQL(let messages) = error else {
                Issue.record("expected .graphQL, got \(error)")
                return
            }
            #expect(messages == ["Resource not accessible by integration"])
        }
    }

    @Test("a body with neither data nor errors throws rather than reading as empty")
    func neitherDataNorErrors() throws {
        do {
            _ = try PullRequestDecoder.decodeTeams(Data("{}".utf8))
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    // MARK: - Persistence shape

    /// The list is persisted so a failed discovery can fall back to it rather
    /// than emptying the section, which means the shape has to round-trip.
    @Test("a team round-trips through JSON")
    func codable() throws {
        let team = Team(
            combinedSlug: "Lansweeper/asset-cortex",
            organization: "Lansweeper",
            name: "Asset Cortex"
        )

        let decoded = try JSONDecoder().decode(
            Team.self, from: try JSONEncoder().encode(team)
        )

        #expect(decoded == team)
    }
}
