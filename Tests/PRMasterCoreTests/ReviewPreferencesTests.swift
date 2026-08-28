import Foundation
import Testing
@testable import PRMasterCore

private func preferences(_ suite: String) -> UserDefaultsPreferences {
    let name = "ReviewPreferencesTests.\(suite)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return UserDefaultsPreferences(defaults: defaults)
}

private func rawDefaults(_ suite: String) -> UserDefaults {
    let name = "ReviewPreferencesTests.\(suite)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func team(_ slug: String) -> Team {
    Team(combinedSlug: "Lansweeper/\(slug)", organization: "Lansweeper", name: slug.capitalized)
}

@Suite("Review preferences")
struct ReviewPreferencesTests {

    // MARK: - The window

    /// An absent key must read as the default the feature shipped with, not as
    /// off. Two weeks is a measurement rather than a taste — see `ReviewWindow`.
    @Test("an absent window reads as two weeks")
    func absentWindow() {
        #expect(preferences("absentWindow").reviewWindow() == .twoWeeks)
        #expect(preferences("absentWindow2").reviewWindow() == ReviewWindow.default)
    }

    /// The one failure nobody would notice: a downgrade, or a stray
    /// `defaults write`, silently emptying the section. Falling back to `off`
    /// would do exactly that — the same rule `MergedWindow` and `StaleThreshold`
    /// both document.
    @Test("an unrecognised window falls back to two weeks rather than off")
    func unrecognisedWindow() {
        let defaults = rawDefaults("garbageWindow")
        defaults.set("fortnight-ish", forKey: "reviewWindow")

        #expect(UserDefaultsPreferences(defaults: defaults).reviewWindow() == .twoWeeks)
    }

    @Test("a stored window round-trips, including off")
    func windowRoundTrips() {
        let prefs = preferences("windowRoundTrip")

        prefs.setReviewWindow(.oneMonth)
        #expect(prefs.reviewWindow() == .oneMonth)
        // Off is the case a user actively chose, so it has to survive.
        prefs.setReviewWindow(.off)
        #expect(prefs.reviewWindow() == .off)
    }

    /// The raw string, not an index — `defaults read com.jcll.PRMaster` is how
    /// this gets debugged, and "2" says nothing.
    @Test("the window is stored as its raw string")
    func windowStoredAsString() {
        let defaults = rawDefaults("windowString")
        UserDefaultsPreferences(defaults: defaults).setReviewWindow(.oneWeek)

        #expect(defaults.string(forKey: "reviewWindow") == "oneWeek")
    }

    // MARK: - The team blocklist

    @Test("an absent blocklist hides nothing")
    func absentBlocklist() {
        #expect(preferences("absentBlocklist").teamFilter() == TeamFilter())
        #expect(preferences("absentBlocklist2").teamFilter().disabledTeams.isEmpty)
    }

    @Test("a stored blocklist round-trips")
    func blocklistRoundTrips() {
        let prefs = preferences("blocklistRoundTrip")

        prefs.setTeamFilter(TeamFilter(disabledTeams: ["Lansweeper/cloud-2"]))
        #expect(prefs.teamFilter().disabledTeams == ["Lansweeper/cloud-2"])

        // Emptying it again has to persist too, or a team could never come back.
        prefs.setTeamFilter(TeamFilter())
        #expect(prefs.teamFilter().disabledTeams.isEmpty)
    }

    /// Sorted so the stored array is stable and readable under
    /// `defaults read com.jcll.PRMaster`, the same reason `setFilter` sorts the
    /// hidden organizations.
    @Test("the blocklist is stored sorted")
    func blocklistStoredSorted() {
        let defaults = rawDefaults("blocklistSorted")
        UserDefaultsPreferences(defaults: defaults).setTeamFilter(
            TeamFilter(disabledTeams: [
                "Lansweeper/node-maintainers", "Lansweeper/asset-cortex", "Lansweeper/cloud-2",
            ])
        )

        #expect(defaults.stringArray(forKey: "disabledTeams") == [
            "Lansweeper/asset-cortex", "Lansweeper/cloud-2", "Lansweeper/node-maintainers",
        ])
    }

    // MARK: - The team list

    /// Persisted so a failed discovery can fall back to the last good list rather
    /// than emptying the section — the rule `promotions` and `shipments` follow.
    @Test("an absent team list reads as nothing discovered yet")
    func absentTeams() {
        #expect(preferences("absentTeams").knownTeams().isEmpty)
    }

    @Test("a stored team list round-trips whole")
    func teamsRoundTrip() {
        let prefs = preferences("teamsRoundTrip")
        let teams = [team("asset-cortex"), team("cloud-2")]

        prefs.setKnownTeams(teams)
        #expect(prefs.knownTeams() == teams)
    }

    /// Written by an older shape, or corrupted. Reading it as "nothing discovered
    /// yet" costs one request to rebuild, which is the safe direction — the same
    /// call `appLocations` makes.
    @Test("an unreadable team list reads as empty rather than throwing")
    func corruptTeams() {
        let defaults = rawDefaults("corruptTeams")
        defaults.set(Data("not json at all".utf8), forKey: "knownTeams")

        #expect(UserDefaultsPreferences(defaults: defaults).knownTeams().isEmpty)
    }

    @Test("a team list stored as the wrong type reads as empty")
    func wrongTypeTeams() {
        let defaults = rawDefaults("wrongTypeTeams")
        defaults.set("a string, not data", forKey: "knownTeams")

        #expect(UserDefaultsPreferences(defaults: defaults).knownTeams().isEmpty)
    }

    // MARK: - Independence

    /// Three separate keys: switching a team off must not disturb the window, and
    /// neither must touch the keys the rest of the app already owns.
    @Test("the three settings do not disturb each other")
    func independent() {
        let prefs = preferences("independent")

        prefs.setReviewWindow(.oneWeek)
        prefs.setTeamFilter(TeamFilter(disabledTeams: ["Lansweeper/cloud-2"]))
        prefs.setKnownTeams([team("asset-cortex")])

        #expect(prefs.reviewWindow() == .oneWeek)
        #expect(prefs.teamFilter().disabledTeams == ["Lansweeper/cloud-2"])
        #expect(prefs.knownTeams().count == 1)
        // And the neighbours are untouched.
        #expect(prefs.mergedWindow() == .oneDay)
        #expect(prefs.staleThreshold() == .oneMonth)
        #expect(prefs.filter() == PRFilter())
    }
}
