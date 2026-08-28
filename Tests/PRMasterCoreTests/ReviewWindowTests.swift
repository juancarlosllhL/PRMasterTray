import Foundation
import Testing
@testable import PRMasterCore

@Suite("Review window")
struct ReviewWindowTests {

    private let now = Date(timeIntervalSince1970: 1_786_692_165)

    /// The raw values land in UserDefaults, so renaming a case would silently
    /// reset every existing install to the default — the same trap
    /// `MergedWindow` and `StaleThreshold` both document.
    @Test("raw values are stable strings")
    func rawValuesAreStable() {
        #expect(ReviewWindow.off.rawValue == "off")
        #expect(ReviewWindow.oneWeek.rawValue == "oneWeek")
        #expect(ReviewWindow.twoWeeks.rawValue == "twoWeeks")
        #expect(ReviewWindow.oneMonth.rawValue == "oneMonth")
    }

    @Test("durations match their labels")
    func durations() throws {
        #expect(ReviewWindow.off.duration == nil)

        let day: TimeInterval = 86_400
        #expect(try #require(ReviewWindow.oneWeek.duration) == 7 * day)
        #expect(try #require(ReviewWindow.twoWeeks.duration) == 14 * day)
        #expect(try #require(ReviewWindow.oneMonth.duration) == 30 * day)
    }

    @Test("every case has a label for the picker")
    func labels() {
        #expect(ReviewWindow.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(ReviewWindow.off.label == "Off")
        #expect(ReviewWindow.oneWeek.label == "1 week")
        #expect(ReviewWindow.twoWeeks.label == "2 weeks")
        #expect(ReviewWindow.oneMonth.label == "1 month")
    }

    /// Two weeks is the default everywhere else in the app, and it is a
    /// measurement rather than a taste: against the account this was built for,
    /// the nine teams had 1846 pull requests pending review with no limit and 76
    /// with this one. The rest were bot pull requests abandoned months ago.
    @Test("the default is two weeks")
    func defaultIsTwoWeeks() {
        #expect(ReviewWindow.default == .twoWeeks)
    }

    // MARK: - The qualifier

    /// `off` sends no search at all rather than one that cannot match, which is
    /// the difference between this and `MergedWindow`: that one rides along with
    /// the open-pull-request search and costs nothing extra, this one is a
    /// request of its own.
    @Test("off yields no qualifier, so the caller skips the request")
    func offHasNoQualifier() {
        #expect(ReviewWindow.off.createdQualifier(now: now) == nil)
    }

    /// The one assertion in here that is load-bearing rather than descriptive.
    ///
    /// A date-only qualifier widens the window by up to 48 hours depending on the
    /// hour of the day it is built at, which is the trap
    /// `MergedWindow.mergedQualifier` documents. Measured against the real
    /// account: `created:>=2026-08-14` answered 66 pull requests where
    /// `created:>2026-08-14T09:20:00Z` answered 62. Asserting the time
    /// components are present is what stops that regressing silently — and it
    /// would regress silently, because GitHub accepts both spellings.
    @Test("the qualifier carries a full timestamp, never a bare date", arguments: [
        ReviewWindow.oneWeek, .twoWeeks, .oneMonth,
    ])
    func qualifierIsTimestamped(window: ReviewWindow) throws {
        let qualifier = try #require(window.createdQualifier(now: now))

        #expect(qualifier.hasPrefix("created:>"))
        #expect(qualifier.contains("T"))
        #expect(qualifier.hasSuffix("Z"))
    }

    /// The qualifier and the local filter come from one number, so a row cannot
    /// be fetched and then hidden, or hidden and then fetched.
    @Test("the qualifier is cut from the same window as the filter")
    func qualifierMatchesWindow() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for window in [ReviewWindow.oneWeek, .twoWeeks, .oneMonth] {
            let duration = try #require(window.duration)
            let cutoff = now.addingTimeInterval(-duration)

            #expect(
                window.createdQualifier(now: now)
                    == "created:>\(formatter.string(from: cutoff))"
            )
            #expect(window.includes(createdAt: cutoff.addingTimeInterval(1), now: now))
            #expect(window.includes(createdAt: cutoff.addingTimeInterval(-1), now: now) == false)
        }
    }

    /// `created:>` is strictly greater, so a pull request opened at exactly the
    /// cutoff is out. Stated because the boundary is the one place the search and
    /// the filter could disagree and nobody would see it.
    @Test("a pull request opened exactly at the cutoff is excluded")
    func cutoffIsExclusive() throws {
        let window = ReviewWindow.twoWeeks
        let duration = try #require(window.duration)
        let cutoff = now.addingTimeInterval(-duration)

        #expect(window.includes(createdAt: cutoff, now: now) == false)
    }

    // MARK: - The filter

    @Test("a pull request inside the window is kept and one outside is dropped", arguments: [
        (ReviewWindow.oneWeek, 6.0, true),
        (ReviewWindow.oneWeek, 8.0, false),
        (ReviewWindow.twoWeeks, 13.0, true),
        (ReviewWindow.twoWeeks, 15.0, false),
        (ReviewWindow.oneMonth, 29.0, true),
        (ReviewWindow.oneMonth, 31.0, false),
    ])
    func boundaries(window: ReviewWindow, daysAgo: Double, kept: Bool) {
        let createdAt = now.addingTimeInterval(-daysAgo * 86_400)
        #expect(window.includes(createdAt: createdAt, now: now) == kept)
    }

    /// Off is the one that has to hide everything, however recent.
    @Test("off keeps nothing at all")
    func offKeepsNothing() {
        #expect(ReviewWindow.off.includes(createdAt: now, now: now) == false)
        #expect(ReviewWindow.off.includes(createdAt: now.addingTimeInterval(-60), now: now) == false)
    }

    /// Happens when the machine's clock trails GitHub's. Hiding a pull request
    /// that has just been opened is the one outcome this must not produce — the
    /// rule `MergedWindow.isRecent` already follows for a merge.
    @Test("a pull request dated in the future is still kept")
    func futureIsKept() {
        #expect(ReviewWindow.twoWeeks.includes(createdAt: now.addingTimeInterval(600), now: now))
    }
}
