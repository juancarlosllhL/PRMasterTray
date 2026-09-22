import Foundation

/// Raw values land in `UserDefaults`, so renaming a case resets every install.
public enum JiraLayout: String, Sendable, Equatable, CaseIterable {
    case list, board

    public static let `default`: JiraLayout = .list

    public var label: String {
        switch self {
        case .list:  return "List"
        case .board: return "Board"
        }
    }
}
