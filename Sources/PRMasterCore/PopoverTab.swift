import Foundation

/// `String`-backed: the raw value reaches `UserDefaults`.
public enum PopoverTab: String, Sendable, Equatable, CaseIterable {
    case pullRequests, jira

    public static let `default`: PopoverTab = .pullRequests

    public var label: String {
        switch self {
        case .pullRequests: return "Pull requests"
        case .jira:         return "Jira"
        }
    }

    public var symbolName: String {
        switch self {
        case .pullRequests: return "arrow.triangle.pull"
        case .jira:         return "square.stack.3d.up"
        }
    }

    /// Total, so a value stored by a future version cannot strand the popover
    /// on a tab this build does not have.
    public static func resolve(requested: PopoverTab, visible: [PopoverTab]) -> PopoverTab {
        visible.contains(requested) ? requested : .default
    }
}
