import Foundation
import Testing
@testable import PRMasterCore

private func team(_ slug: String) -> Team {
    Team(
        combinedSlug: "Lansweeper/\(slug)",
        organization: "Lansweeper",
        name: slug.capitalized
    )
}

@Suite("Team filter")
struct TeamFilterTests {

    /// The load-bearing case, and the reason this stores the teams to *hide*
    /// rather than the ones to show.
    ///
    /// With an allowlist, the first review request from a team the user has just
    /// joined would be invisible — and they would have no way to know it existed
    /// to go looking for. A blocklist can only ever hide something the user
    /// named. The same choice `PRFilter` documents for organizations, and it
    /// matters more here: teams are handed to you by somebody else.
    @Test("a team nobody has named is shown")
    func unknownTeamIsShown() {
        let filter = TeamFilter()

        #expect(filter.shows(team("asset-cortex")))
        #expect(filter.shows(team("a-team-invented-tomorrow")))
    }

    @Test("the default hides nothing at all")
    func defaultHidesNothing() {
        #expect(TeamFilter().disabledTeams.isEmpty)
        #expect(TeamFilter().isActive == false)
    }

    @Test("a named team is hidden and the rest are not")
    func namedTeamIsHidden() {
        let filter = TeamFilter(disabledTeams: ["Lansweeper/cloud-2"])

        #expect(filter.shows(team("cloud-2")) == false)
        #expect(filter.shows(team("asset-cortex")))
        #expect(filter.isActive)
    }

    @Test("flipping a team off and back on round-trips")
    func roundTrips() {
        var filter = TeamFilter()
        let cloud = team("cloud-2")

        filter.set(cloud, shown: false)
        #expect(filter.shows(cloud) == false)
        #expect(filter.disabledTeams == ["Lansweeper/cloud-2"])

        filter.set(cloud, shown: true)
        #expect(filter.shows(cloud))
        #expect(filter.disabledTeams.isEmpty)
    }

    /// Switching an already-hidden team off, or an already-shown one on, must be
    /// a no-op rather than accumulating anything: the settings toggle can be
    /// written to with the value it already has.
    @Test("setting the value it already has changes nothing")
    func idempotent() {
        var filter = TeamFilter(disabledTeams: ["Lansweeper/cloud-2"])

        filter.set(team("cloud-2"), shown: false)
        #expect(filter.disabledTeams == ["Lansweeper/cloud-2"])

        filter.set(team("asset-cortex"), shown: true)
        #expect(filter.disabledTeams == ["Lansweeper/cloud-2"])
    }

    /// Teams come and go — somebody leaves one, or it is deleted in GitHub. The
    /// stored name outliving the team must not resurrect it or throw; it simply
    /// applies to nothing.
    @Test("a stored name for a team that no longer exists applies to nothing")
    func staleEntryIsHarmless() {
        let filter = TeamFilter(disabledTeams: [
            "Lansweeper/a-team-that-was-deleted", "Lansweeper/cloud-2",
        ])

        #expect(filter.enabled(from: [team("cloud-2"), team("datanauts")])
            .map(\.combinedSlug) == ["Lansweeper/datanauts"])
    }

    /// The order is the caller's, which is the sorted order `decodeTeams`
    /// produces — the settings list reads in it and the search aliases are
    /// assigned in it.
    @Test("enabled keeps the order it was given")
    func enabledPreservesOrder() {
        let filter = TeamFilter(disabledTeams: ["Lansweeper/cloud-2"])
        let teams = [team("asset-cortex"), team("cloud-2"), team("datanauts")]

        #expect(filter.enabled(from: teams).map(\.combinedSlug) == [
            "Lansweeper/asset-cortex", "Lansweeper/datanauts",
        ])
    }

    @Test("disabling every team leaves nothing enabled")
    func allDisabled() {
        let teams = [team("asset-cortex"), team("cloud-2")]
        let filter = TeamFilter(disabledTeams: Set(teams.map(\.combinedSlug)))

        #expect(filter.enabled(from: teams).isEmpty)
    }
}
