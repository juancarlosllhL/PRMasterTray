import Foundation
import Testing
@testable import PRMasterCore

/// A fixed clock. Staleness is a function of three things and one of them is the
/// current time, so every case here pins it rather than reading `Date()`.
private let now = Date(timeIntervalSince1970: 1_000_000_000)

private func opened(daysAgo days: Double) -> Date {
    now.addingTimeInterval(-days * 86_400)
}

@Suite("StaleThreshold")
struct StaleThresholdTests {

    // MARK: storage contract

    /// Raw values are a storage contract — they are what lands in UserDefaults,
    /// so renaming a case would silently reset everybody to the default.
    @Test("raw values are the stored strings", arguments: [
        (StaleThreshold.off, "off"),
        (StaleThreshold.twoWeeks, "twoWeeks"),
        (StaleThreshold.oneMonth, "oneMonth"),
        (StaleThreshold.threeMonths, "threeMonths"),
        (StaleThreshold.sixMonths, "sixMonths"),
    ])
    func rawValues(threshold: StaleThreshold, raw: String) {
        #expect(threshold.rawValue == raw)
        #expect(StaleThreshold(rawValue: raw) == threshold)
    }

    @Test("an unrecognised string is not a threshold")
    func unknownIsNil() {
        #expect(StaleThreshold(rawValue: "fortnight") == nil)
    }

    /// `allCases` is what the settings picker renders, so its contents and its
    /// order are both part of the design rather than an implementation detail.
    @Test("the picker offers off first, then ascending durations")
    func caseOrder() {
        #expect(StaleThreshold.allCases == [
            .off, .twoWeeks, .oneMonth, .threeMonths, .sixMonths,
        ])
    }

    @Test("every threshold has a label", arguments: [
        (StaleThreshold.off, "Off"),
        (StaleThreshold.twoWeeks, "2 weeks"),
        (StaleThreshold.oneMonth, "1 month"),
        (StaleThreshold.threeMonths, "3 months"),
        (StaleThreshold.sixMonths, "6 months"),
    ])
    func labels(threshold: StaleThreshold, label: String) {
        #expect(threshold.label == label)
    }

    // MARK: off

    /// The escape hatch for anybody who finds the marker noisy. It has to hold
    /// at every age, including absurd ones.
    @Test("off is never stale, at any age", arguments: [0.0, 1, 14, 30, 90, 180, 400, 10_000])
    func offNeverStale(age: Double) {
        #expect(StaleThreshold.off.isStale(createdAt: opened(daysAgo: age), now: now) == false)
    }

    // MARK: the boundary

    /// Strictly greater than, so the marker never appears a day early. This is
    /// the one comparison in the rule that can be wrong in a way nobody notices
    /// until they argue with the number on the row.
    @Test("a pull request opened exactly at the threshold is not yet stale", arguments: [
        (StaleThreshold.twoWeeks, 14.0),
        (StaleThreshold.oneMonth, 30.0),
        (StaleThreshold.threeMonths, 90.0),
        (StaleThreshold.sixMonths, 180.0),
    ])
    func exactlyAtThresholdIsNotStale(threshold: StaleThreshold, days: Double) {
        #expect(threshold.isStale(createdAt: opened(daysAgo: days), now: now) == false)
    }

    @Test("one second past the threshold is stale", arguments: [
        (StaleThreshold.twoWeeks, 14.0),
        (StaleThreshold.oneMonth, 30.0),
        (StaleThreshold.threeMonths, 90.0),
        (StaleThreshold.sixMonths, 180.0),
    ])
    func justPastThresholdIsStale(threshold: StaleThreshold, days: Double) {
        let createdAt = opened(daysAgo: days).addingTimeInterval(-1)
        #expect(threshold.isStale(createdAt: createdAt, now: now))
    }

    @Test("a day short of the threshold is not stale", arguments: [
        (StaleThreshold.twoWeeks, 13.0),
        (StaleThreshold.oneMonth, 29.0),
        (StaleThreshold.threeMonths, 89.0),
        (StaleThreshold.sixMonths, 179.0),
    ])
    func shortOfThresholdIsNotStale(threshold: StaleThreshold, days: Double) {
        #expect(threshold.isStale(createdAt: opened(daysAgo: days), now: now) == false)
    }

    /// A longer threshold must never mark something a shorter one leaves alone —
    /// the four durations have to stay ordered by what they catch.
    @Test("a wider threshold catches strictly less")
    func thresholdsAreOrdered() {
        let createdAt = opened(daysAgo: 45)
        #expect(StaleThreshold.twoWeeks.isStale(createdAt: createdAt, now: now))
        #expect(StaleThreshold.oneMonth.isStale(createdAt: createdAt, now: now))
        #expect(StaleThreshold.threeMonths.isStale(createdAt: createdAt, now: now) == false)
        #expect(StaleThreshold.sixMonths.isStale(createdAt: createdAt, now: now) == false)
    }

    /// Clock skew, or a machine whose date is wrong. Nothing opened in the
    /// future is old, and the comparison must not wrap into "stale".
    @Test("a creation date in the future is never stale")
    func futureIsNotStale() {
        let createdAt = now.addingTimeInterval(86_400)
        for threshold in StaleThreshold.allCases {
            #expect(threshold.isStale(createdAt: createdAt, now: now) == false)
        }
    }
}

@Suite("StaleAge")
struct StaleAgeTests {

    @Test("the age reads in the largest unit that stays honest", arguments: [
        (0.0, "0 days"),
        (1.0, "1 day"),
        (2.0, "2 days"),
        (31.0, "31 days"),
        // 60 days is where days stop being readable and months take over.
        (59.0, "59 days"),
        (60.0, "2 months"),
        (90.0, "3 months"),
        (364.0, "12 months"),
        // A year, likewise, once months stop being readable.
        (365.0, "1 year"),
        (400.0, "1 year"),
        (730.0, "2 years"),
    ])
    func label(days: Double, expected: String) {
        #expect(StaleAge.label(createdAt: opened(daysAgo: days), now: now) == expected)
    }

    /// The duration alone, with no trailing "old". Measured against the real
    /// popover, those four characters were enough to push the pull request number
    /// off the end of the longest rows — the clock glyph beside it already says
    /// what the number means.
    @Test("the label carries no suffix that would widen the row")
    func noSuffix() {
        let label = StaleAge.label(createdAt: opened(daysAgo: 150), now: now)
        #expect(label == "5 months")
        #expect(label.contains("old") == false)
        #expect(label.contains("ago") == false)
    }

    /// The row shows this string verbatim, so a stray "1 days" would be visible to
    /// every user with a day-old pull request.
    @Test("a count of one is never pluralised", arguments: [1.0, 30.0, 365.0])
    func singular(days: Double) {
        let label = StaleAge.label(createdAt: opened(daysAgo: days), now: now)
        #expect(label.contains("1 days") == false)
        #expect(label.contains("1 months") == false)
        #expect(label.contains("1 years") == false)
    }

    /// Same reason `PRListView.ago` guards against "in 0 seconds": a clock that
    /// is slightly ahead must not produce a negative age on the row.
    @Test("a creation date in the future reads as zero, not negative")
    func futureClamps() {
        let label = StaleAge.label(createdAt: now.addingTimeInterval(86_400), now: now)
        #expect(label == "0 days")
    }

    /// Hand-rolled rather than RelativeDateTimeFormatter, so the digits are not
    /// locale-grouped — the same trap `Text(verbatim:)` guards in the row, where
    /// PR #1204 once rendered as "1.204".
    @Test("a four-digit day count is not grouped")
    func noGrouping() {
        #expect(StaleAge.label(createdAt: opened(daysAgo: 1200), now: now) == "3 years")
        #expect(StaleAge.label(createdAt: opened(daysAgo: 1000), now: now).contains(",") == false)
    }
}
