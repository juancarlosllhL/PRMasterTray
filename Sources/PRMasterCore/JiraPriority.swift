import Foundation

/// Ordered by Jira's own numeric priority id, verified live on this site.
/// `unset` is 10000 rather than 6, which keeps it sorting last, and is spelled
/// that way because `.none` collides with `Optional.none`.
public enum JiraPriority: Sendable, Equatable, CaseIterable {
    case critical, high, medium, low, lowest, unset

    public var order: Int {
        switch self {
        case .critical: return 1
        case .high:     return 2
        case .medium:   return 3
        case .low:      return 4
        case .lowest:   return 5
        case .unset:    return 10_000
        }
    }

    public var name: String {
        switch self {
        case .critical: return "Critical"
        case .high:     return "High"
        case .medium:   return "Medium"
        case .low:      return "Low"
        case .lowest:   return "Lowest"
        case .unset:    return "None"
        }
    }

    /// An id this site does not define resolves to `unset`, never `critical`,
    /// so an unrecognised value cannot float to the top of the list.
    public init?(id: String) {
        guard let match = Self.allCases.first(where: { String($0.order) == id })
        else { return nil }
        self = match
    }

    /// Drawn as an arrow, so the direction carries the meaning where monochrome
    /// leaves no colour to read.
    public var symbolName: String? {
        switch self {
        case .critical: return "chevron.up.2"
        case .high:     return "chevron.up"
        case .medium:   return "equal"
        case .low:      return "chevron.down"
        case .lowest:   return "chevron.down.2"
        case .unset:    return nil
        }
    }

    public var tint: ReadinessTint {
        switch self {
        case .critical, .high: return .red
        case .medium:         return .yellow
        case .low, .lowest:   return .blue
        case .unset:          return .gray
        }
    }

    public var isWorthShowing: Bool { self != .unset }
}
