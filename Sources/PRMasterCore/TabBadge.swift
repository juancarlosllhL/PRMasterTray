import Foundation

public enum TabBadge: Sendable, Equatable {
    case none
    case count(Int)
    case warning

    /// `loading` yields no badge rather than a zero, which would read as
    /// "nothing here" before the app has any right to say so.
    public static func resolve(
        state: PaneState,
        count: Int,
        hasRoutedFailure: Bool = false
    ) -> TabBadge {
        if state == .failed || hasRoutedFailure { return .warning }
        if state == .loading { return .none }
        return count > 0 ? .count(count) : .none
    }
}
