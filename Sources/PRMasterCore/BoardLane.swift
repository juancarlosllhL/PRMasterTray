import Foundation

/// A board column, and the target of a move. Ordered the way work moves, so
/// how far a status is from a target is a difference of raw values.
public enum BoardLane: Int, Sendable, CaseIterable, Comparable {
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

    public static func < (lhs: BoardLane, rhs: BoardLane) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension BoardLane {

    /// A GitHub Status option is only a name. Backlog and refinement are not yet
    /// work, so they start hidden. One that names nothing known lands in progress,
    /// as Jira's unknown category does: visible and fixable beats hidden.
    public static func guess(optionName: String) -> BoardLane? {
        let words = Set(optionName.lowercased().split { !$0.isLetter }.map(String.init))
        func any(_ set: Set<String>) -> Bool { !words.isDisjoint(with: set) }

        if any(["blocked", "hold", "cancelled", "canceled", "won", "parked", "backlog", "refinement"]) { return nil }
        if any(["done", "closed", "released", "shipped", "complete", "completed"]) { return .done }
        if any(["qa", "test", "testing"]) { return .testing }
        if any(["review", "reviewing"]) { return .reviewing }
        if any(["todo", "ready", "new", "draft"]) || words == ["to", "do"] { return .toDo }
        return .inProgress
    }
}
