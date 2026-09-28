import Foundation

/// A board column, and the target of a move. Ordered the way work moves, so
/// how far a status is from a target is a difference of raw values.
public enum JiraLane: Int, Sendable, CaseIterable, Comparable {
    case toDo, inProgress, reviewing, testing, done

    public var title: String {
        switch self {
        case .toDo:       return "To do"
        case .inProgress: return "In progress"
        case .reviewing:  return "Reviewing"
        case .testing:    return "Testing"
        case .done:       return "Done"
        }
    }

    public static func < (lhs: JiraLane, rhs: JiraLane) -> Bool { lhs.rawValue < rhs.rawValue }
}
