import Foundation

/// How long a merged pull request stays in the list.
///
/// One rule rather than two: the window the search asks GitHub for and the
/// window the list displays are the same number, derived here. Two numbers
/// would eventually disagree, and a row would either vanish while still being
/// fetched or be fetched and never shown.
///
/// There is deliberately no second timer to retire a released row sooner. The
/// section empties itself overnight, and a shipped version is worth seeing for
/// the rest of the day it shipped in.
public enum ShipmentRetention {

    /// 24 hours. Not a setting, for now: making it one is the obvious follow-up,
    /// and until somebody wants a different number an unused picker is just
    /// another thing that can be set wrong.
    public static let window: TimeInterval = 24 * 3600

    /// Whether a merge is recent enough to still be worth showing.
    ///
    /// A merge dated in the future counts as recent. That happens when the
    /// machine's clock trails GitHub's, and hiding a merge that has just landed
    /// is the one outcome this must not produce.
    public static func isRecent(mergedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(mergedAt) <= window
    }

    public static func recent(_ merged: [MergedPullRequest], now: Date) -> [MergedPullRequest] {
        merged.filter { isRecent(mergedAt: $0.mergedAt, now: now) }
    }

    /// The `merged:>…` qualifier for the search, cut from the same window.
    ///
    /// A full timestamp rather than a date: `merged:>2026-08-13` would widen the
    /// window to anything up to 48 hours depending on the hour of the day, and
    /// the list would then disagree with `isRecent` about half its rows.
    public static func mergedQualifier(now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "merged:>\(formatter.string(from: now.addingTimeInterval(-window)))"
    }
}
