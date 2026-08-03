import Foundation

/// How long a pull request may stay open before the list says so.
///
/// The second axis on a row, and deliberately not part of `Readiness`. That one
/// is a pure function of the pull request; this needs a clock and a user setting
/// as well, and folding it in would have broken every `readiness ==` comparison
/// in the app — a stale-but-ready PR would have stopped notifying and lost its
/// merge button with nobody deciding that.
///
/// Backed by `String` because the raw value is what lands in `UserDefaults` —
/// renaming a case would silently reset every existing install to the default.
public enum StaleThreshold: String, Sendable, Equatable, CaseIterable {
    case off, twoWeeks, oneMonth, threeMonths, sixMonths

    /// Whole days, and a month is 30 of them.
    ///
    /// Not a calendar calculation, on purpose: this is a heuristic for "you have
    /// forgotten about this", the labels are approximate by their own wording,
    /// and nobody is counting. `nil` is what makes `off` mean off.
    var days: Int? {
        switch self {
        case .off:         return nil
        case .twoWeeks:    return 14
        case .oneMonth:    return 30
        case .threeMonths: return 90
        case .sixMonths:   return 180
        }
    }

    /// What the settings picker shows for this case.
    public var label: String {
        switch self {
        case .off:         return "Off"
        case .twoWeeks:    return "2 weeks"
        case .oneMonth:    return "1 month"
        case .threeMonths: return "3 months"
        case .sixMonths:   return "6 months"
        }
    }

    /// Whether a pull request opened at `createdAt` counts as stale.
    ///
    /// Strictly greater than, so a pull request that has been open for exactly
    /// the chosen period is not marked yet. The marker appearing a day early is
    /// the version of this a user would argue with.
    ///
    /// Measured from when the pull request was opened rather than from its last
    /// activity: `PRStore.updateBehindBranches` pushes a merge commit into behind
    /// branches off the poll loop, which bumps `updatedAt`. Against a base branch
    /// that keeps moving, the app would have gone on resetting its own staleness
    /// signal forever, and nothing would ever have been marked.
    public func isStale(createdAt: Date, now: Date) -> Bool {
        guard let days else { return false }
        return now.timeIntervalSince(createdAt) > Double(days) * 86_400
    }
}

/// The age shown on a stale row.
///
/// Hand-rolled rather than `RelativeDateTimeFormatter`, for two reasons: the
/// output is deterministic, so the boundaries can be table-tested rather than
/// eyeballed, and it allocates nothing — that formatter is expensive to build and
/// this runs per visible row.
public enum StaleAge {

    /// Just the duration — "5 months", not "5 months old".
    ///
    /// The wording is load-bearing rather than terse for its own sake. A row is
    /// 380pt wide and its second line already carries `owner/repo #1234` and a
    /// status; measured against the real popover, the trailing " old" was enough
    /// to push the pull request number off the end of the longest rows. The clock
    /// glyph beside it already says what the number means, and the accessibility
    /// label spells it out in full.
    ///
    /// Days, then months, then years, switching only where the smaller unit stops
    /// being readable: "74 days" is a number nobody parses, "2 months" is. The
    /// switch is deliberately late — just past the threshold a precise day count
    /// is more useful than a rounded month.
    public static func label(createdAt: Date, now: Date) -> String {
        // Clamped because a machine whose clock is ahead of GitHub's would
        // otherwise put a negative number on the row.
        let days = max(0, Int(now.timeIntervalSince(createdAt) / 86_400))
        if days < 60 { return unit(days, "day") }
        if days < 365 { return unit(days / 30, "month") }
        return unit(days / 365, "year")
    }

    /// Interpolating an `Int` rather than formatting it, so the digits are never
    /// locale-grouped — the trap that had PR #1204 rendering as "1.204".
    private static func unit(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}
