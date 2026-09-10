import Foundation

/// Which pane of the popover is on screen. `String`-backed: the raw value reaches
/// `UserDefaults`.
public enum PopoverTab: String, Sendable, Equatable, CaseIterable {
    case mine, teams, merged, jira

    public static let `default`: PopoverTab = .mine

    public var label: String {
        switch self {
        case .mine:   return "Mine"
        case .teams:  return "Teams"
        case .merged: return "Merged"
        case .jira:   return "Jira"
        }
    }

    public var symbolName: String {
        switch self {
        case .mine:   return "arrow.triangle.pull"
        case .teams:  return "person.2"
        case .merged: return "shippingbox"
        case .jira:   return "square.stack.3d.up"
        }
    }

    /// Declared order, so a tab does not move when another is switched off —
    /// Command-digit indexes into this. Mine is never dropped.
    public static func visible(
        mergedWindow: MergedWindow,
        reviewWindow: ReviewWindow,
        jiraConfigured: Bool
    ) -> [PopoverTab] {
        allCases.filter { tab in
            switch tab {
            case .mine:   return true
            case .teams:  return reviewWindow != .off
            case .merged: return mergedWindow != .off
            case .jira:   return jiraConfigured
            }
        }
    }

    /// A setting can change while the popover is shut, stranding a selection on a
    /// tab no longer offered.
    public static func resolve(requested: PopoverTab, visible: [PopoverTab]) -> PopoverTab {
        visible.contains(requested) ? requested : .default
    }
}
