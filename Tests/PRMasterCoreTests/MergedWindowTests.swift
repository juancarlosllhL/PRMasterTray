import Foundation
import Testing
@testable import PRMasterCore

@Suite("Merged window")
struct MergedWindowTests {

    private let now = Date(timeIntervalSince1970: 1_786_692_165)

    /// The raw values land in UserDefaults, so renaming a case would silently
    /// reset every existing install to the default — the same trap
    /// `StaleThreshold` documents.
    @Test("raw values are stable strings")
    func rawValuesAreStable() {
        #expect(MergedWindow.off.rawValue == "off")
        #expect(MergedWindow.oneDay.rawValue == "oneDay")
        #expect(MergedWindow.threeDays.rawValue == "threeDays")
        #expect(MergedWindow.oneWeek.rawValue == "oneWeek")
    }

    @Test("durations match their labels")
    func durations() throws {
        #expect(MergedWindow.off.duration == nil)

        let day: TimeInterval = 86_400
        #expect(try #require(MergedWindow.oneDay.duration) == day)
        #expect(try #require(MergedWindow.threeDays.duration) == 3 * day)
        #expect(try #require(MergedWindow.oneWeek.duration) == 7 * day)
    }

    @Test("a merge inside the window is kept and one outside is dropped", arguments: [
        (MergedWindow.oneDay, 23.0, true),
        (MergedWindow.oneDay, 25.0, false),
        (MergedWindow.threeDays, 70.0, true),
        (MergedWindow.threeDays, 73.0, false),
        (MergedWindow.oneWeek, 167.0, true),
        (MergedWindow.oneWeek, 169.0, false),
    ])
    func boundaries(window: MergedWindow, hoursAgo: Double, kept: Bool) {
        let mergedAt = now.addingTimeInterval(-hoursAgo * 3600)
        #expect(window.isRecent(mergedAt: mergedAt, now: now) == kept)
    }

    /// Off is the one that has to hide everything, however recent.
    @Test("off keeps nothing at all")
    func offKeepsNothing() {
        #expect(MergedWindow.off.isRecent(mergedAt: now, now: now) == false)
        #expect(MergedWindow.off.isRecent(mergedAt: now.addingTimeInterval(-60), now: now) == false)
    }

    @Test("a merge timestamped in the future is still kept")
    func futureIsKept() {
        #expect(MergedWindow.oneDay.isRecent(mergedAt: now.addingTimeInterval(600), now: now))
    }

    /// The qualifier and the filter come from one number, so a row cannot be
    /// fetched and then hidden, or hidden and then fetched.
    @Test("the qualifier is cut from the same window as the filter")
    func qualifierMatchesWindow() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for window in [MergedWindow.oneDay, .threeDays, .oneWeek] {
            let cutoff = now.addingTimeInterval(-window.duration!)
            #expect(window.mergedQualifier(now: now) == "merged:>\(formatter.string(from: cutoff))")
            #expect(window.isRecent(mergedAt: cutoff.addingTimeInterval(1), now: now))
            #expect(window.isRecent(mergedAt: cutoff.addingTimeInterval(-1), now: now) == false)
        }
    }

    /// A wider window reaches back past more releases. Asking for only the five
    /// newest would leave a merge near the far edge unable to find the release
    /// that first contained it, and the resolver would then either say nothing
    /// or name a later version than the true one.
    @Test("the releases page grows with the window")
    func releaseDepthGrows() {
        #expect(MergedWindow.oneDay.releaseDepth < MergedWindow.threeDays.releaseDepth)
        #expect(MergedWindow.threeDays.releaseDepth < MergedWindow.oneWeek.releaseDepth)
        // GitHub refuses a page over 100 outright.
        #expect(MergedWindow.oneWeek.releaseDepth <= 100)
    }

    @Test("every case has a label for the picker")
    func labels() {
        #expect(MergedWindow.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(MergedWindow.off.label == "Off")
    }

    @Test("filtering keeps only the recent merges, in the order given")
    func filtersInOrder() {
        let fresh = stub(id: "fresh", mergedAt: now.addingTimeInterval(-3600))
        let old = stub(id: "old", mergedAt: now.addingTimeInterval(-48 * 3600))

        #expect(MergedWindow.oneDay.recent([fresh, old], now: now).map(\.id) == ["fresh"])
        #expect(MergedWindow.threeDays.recent([fresh, old], now: now).map(\.id) == ["fresh", "old"])
        #expect(MergedWindow.off.recent([fresh, old], now: now).isEmpty)
    }

    private func stub(id: String, mergedAt: Date) -> MergedPullRequest {
        MergedPullRequest(
            id: id,
            number: 1,
            title: "t",
            url: URL(string: "https://github.com/acme/widget-service/pull/1")!,
            repo: "acme/widget-service",
            repositoryID: "R_1",
            isPrivate: false,
            mergedAt: mergedAt,
            mergeCommitOid: nil,
            rollupState: nil,
            contexts: []
        )
    }

    // MARK: persistence

    /// An absent key must read as the behaviour that shipped before this
    /// setting existed, or installing an update changes what people see.
    @Test("an absent preference reads as one day")
    func absentDefaultsToOneDay() {
        let defaults = UserDefaults(suiteName: "MergedWindowTests.absent")!
        defaults.removePersistentDomain(forName: "MergedWindowTests.absent")
        #expect(UserDefaultsPreferences(defaults: defaults).mergedWindow() == .oneDay)
    }

    /// Same rule as the stale threshold: an unrecognised value must not switch
    /// the section off, which is the one failure nobody would notice.
    @Test("an unrecognised stored value falls back to one day rather than off")
    func unrecognisedFallsBack() {
        let defaults = UserDefaults(suiteName: "MergedWindowTests.garbage")!
        defaults.removePersistentDomain(forName: "MergedWindowTests.garbage")
        defaults.set("fortnight", forKey: "mergedWindow")
        #expect(UserDefaultsPreferences(defaults: defaults).mergedWindow() == .oneDay)
    }

    @Test("a stored window round-trips")
    func roundTrips() {
        let defaults = UserDefaults(suiteName: "MergedWindowTests.roundtrip")!
        defaults.removePersistentDomain(forName: "MergedWindowTests.roundtrip")
        let preferences = UserDefaultsPreferences(defaults: defaults)

        preferences.setMergedWindow(.oneWeek)
        #expect(preferences.mergedWindow() == .oneWeek)
        preferences.setMergedWindow(.off)
        #expect(preferences.mergedWindow() == .off)
    }
}
