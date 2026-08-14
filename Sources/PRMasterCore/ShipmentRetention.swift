import Foundation

/// How long a merged pull request stays in the list.
///
/// One rule rather than two: the window the search asks GitHub for and the
/// window the list displays both come from here. Two numbers would eventually
/// disagree, and a row would either vanish while still being fetched or be
/// fetched and never shown.
///
/// There is deliberately no second timer to retire a released row sooner. The
/// section empties itself on the schedule the user chose, and a shipped version
/// is worth seeing for as long as the rest.
///
/// Backed by `String` because the raw value is what lands in `UserDefaults` —
/// renaming a case would silently reset every existing install to the default.
public enum MergedWindow: String, Sendable, Equatable, CaseIterable {
    case off, oneDay, threeDays, oneWeek

    /// `nil` is what makes `off` mean off.
    public var duration: TimeInterval? {
        switch self {
        case .off:       return nil
        case .oneDay:    return 24 * 3600
        case .threeDays: return 3 * 24 * 3600
        case .oneWeek:   return 7 * 24 * 3600
        }
    }

    /// What the settings picker shows for this case.
    public var label: String {
        switch self {
        case .off:       return "Off"
        case .oneDay:    return "1 day"
        case .threeDays: return "3 days"
        case .oneWeek:   return "1 week"
        }
    }

    /// How many releases to ask each repository for.
    ///
    /// Grows with the window rather than sitting at a flat five, and that is a
    /// correctness matter rather than a tuning one: containment is only ever
    /// decided among the releases actually fetched. A week-old merge in a
    /// repository that ships several times a day would otherwise have every
    /// candidate release be one cut long after it, and the resolver would name
    /// a later version than the one the change first appeared in.
    public var releaseDepth: Int {
        switch self {
        case .off:       return 0
        case .oneDay:    return 5
        case .threeDays: return 20
        case .oneWeek:   return 50
        }
    }

    /// Whether a merge is recent enough to still be worth showing.
    ///
    /// A merge dated in the future counts as recent. That happens when the
    /// machine's clock trails GitHub's, and hiding a merge that has just landed
    /// is the one outcome this must not produce.
    public func isRecent(mergedAt: Date, now: Date) -> Bool {
        guard let duration else { return false }
        return now.timeIntervalSince(mergedAt) <= duration
    }

    public func recent(_ merged: [MergedPullRequest], now: Date) -> [MergedPullRequest] {
        merged.filter { isRecent(mergedAt: $0.mergedAt, now: now) }
    }

    /// The `merged:>…` qualifier for the search, cut from the same window.
    ///
    /// A full timestamp rather than a date: `merged:>2026-08-13` would widen the
    /// window to anything up to 48 hours depending on the hour of the day, and
    /// the list would then disagree with `isRecent` about half its rows.
    ///
    /// `off` asks for merges after this instant, which is nothing. The search
    /// still goes out because it carries the open half too, and one document
    /// costs the same as one document.
    public func mergedQualifier(now: Date) -> String {
        let cutoff = now.addingTimeInterval(-(duration ?? 0))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "merged:>\(formatter.string(from: cutoff))"
    }
}
