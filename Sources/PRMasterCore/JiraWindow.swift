import Foundation

/// How far back the Done section reaches.
///
/// Backed by `String` because the raw value lands in `UserDefaults`.
public enum JiraWindow: String, Sendable, Equatable, CaseIterable {
    case off, oneWeek, twoWeeks, oneMonth

    public static let `default`: JiraWindow = .twoWeeks

    public var days: Int? {
        switch self {
        case .off:      return nil
        case .oneWeek:  return 7
        case .twoWeeks: return 14
        case .oneMonth: return 30
        }
    }

    public var label: String {
        switch self {
        case .off:      return "Off"
        case .oneWeek:  return "1 week"
        case .twoWeeks: return "2 weeks"
        case .oneMonth: return "1 month"
        }
    }

    /// `statusCategoryChangedDate`, not `resolutiondate`: an issue can reach
    /// Done carrying no resolution date, and one such issue was measured inside
    /// the 30 day window on this account.
    public var doneQualifier: String? {
        days.map { "statusCategoryChangedDate >= -\($0)d" }
    }

    public func includes(finishedAt: Date?, now: Date) -> Bool {
        guard let days, let finishedAt else { return false }
        return now.timeIntervalSince(finishedAt) < Double(days) * 86_400
    }
}
