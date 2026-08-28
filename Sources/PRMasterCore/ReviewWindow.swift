import Foundation

/// How recently a pull request must have been opened to be worth reviewing.
///
/// The limit that makes the section possible rather than a preference on top of
/// one. Measured against the account this was built for: its nine teams had 1846
/// open pull requests pending their review with no limit at all, and 76 with two
/// weeks. The excess was almost entirely release-bot and dependency-bump pull
/// requests abandoned months earlier, which nobody is going to approve from a
/// menu bar — so the limit is what separates a list you read from one you scroll
/// past.
///
/// Measured from when the pull request was opened rather than from its last
/// activity, the same choice `StaleThreshold` documents: a bot that rebases its
/// own branch every night would otherwise keep resetting its own age and sit at
/// the top of the list forever.
///
/// Backed by `String` because the raw value is what lands in `UserDefaults` —
/// renaming a case would silently reset every existing install to the default.
public enum ReviewWindow: String, Sendable, Equatable, CaseIterable {
    case off, oneWeek, twoWeeks, oneMonth

    /// What an install that has never touched the setting gets.
    ///
    /// Named rather than left to the preference getter so the number has one home:
    /// the fallback for an absent key and the fallback for an unrecognised one are
    /// the same decision, and neither may be `off` — a downgrade or a stray
    /// `defaults write` silently emptying the section is the one failure nobody
    /// would notice.
    public static let `default`: ReviewWindow = .twoWeeks

    /// `nil` is what makes `off` mean off.
    ///
    /// Whole days, and a month is 30 of them — a heuristic for "recent enough to
    /// still be worth a look", not a calendar calculation. The labels are
    /// approximate by their own wording.
    public var duration: TimeInterval? {
        switch self {
        case .off:      return nil
        case .oneWeek:  return 7 * 86_400
        case .twoWeeks: return 14 * 86_400
        case .oneMonth: return 30 * 86_400
        }
    }

    /// What the settings picker shows for this case.
    public var label: String {
        switch self {
        case .off:      return "Off"
        case .oneWeek:  return "1 week"
        case .twoWeeks: return "2 weeks"
        case .oneMonth: return "1 month"
        }
    }

    /// The `created:>…` qualifier for the search, cut from the same window as
    /// `includes(createdAt:now:)` so a row cannot be fetched and then hidden.
    ///
    /// A full timestamp rather than a date, and that is a correctness matter
    /// rather than a formatting preference — the same trap
    /// `MergedWindow.mergedQualifier` documents. `created:>=2026-08-14` widens the
    /// window by up to 48 hours depending on the hour of the day it is built at:
    /// measured against the real account it answered 66 pull requests where
    /// `created:>2026-08-14T09:20:00Z` answered 62. GitHub accepts both
    /// spellings, so nothing but the test catches the wrong one.
    ///
    /// - Returns: `nil` for `off`, so the caller skips the request entirely. This
    ///   search is a round trip of its own, unlike the merged one that rides
    ///   along with the open pull requests, so there is nothing to be gained by
    ///   sending one that cannot match.
    public func createdQualifier(now: Date) -> String? {
        guard let duration else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "created:>\(formatter.string(from: now.addingTimeInterval(-duration)))"
    }

    /// Whether a pull request opened at `createdAt` is recent enough to list.
    ///
    /// Strictly inside, matching `created:>` exactly: a pull request opened at the
    /// cutoff is out on both sides of the wire. The boundary is the one place the
    /// search and this filter could disagree without anybody noticing.
    ///
    /// A pull request dated in the future counts as recent. That happens when the
    /// machine's clock trails GitHub's, and hiding a pull request that has just
    /// been opened is the one outcome this must not produce.
    public func includes(createdAt: Date, now: Date) -> Bool {
        guard let duration else { return false }
        return now.timeIntervalSince(createdAt) < duration
    }
}
