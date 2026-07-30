/// Semantic colour for a readiness state. Named rather than concrete so the
/// mapping stays in the testable core and only the SwiftUI layer knows about
/// actual `Color` values.
/// `CaseIterable` so `PaletteTests` can assert the contrast floor across every
/// tint rather than across the ones somebody remembered to list.
public enum ReadinessTint: Sendable, Equatable, CaseIterable {
    case green, yellow, blue, red, orange, gray
}

extension Readiness {

    /// SF Symbol shown at the leading edge of each row.
    public var symbolName: String {
        switch self {
        case .ready:         return "checkmark.circle.fill"
        case .behind:        return "arrow.down.circle"
        case .blocked:       return "eye.circle"
        case .checksPending: return "clock"
        case .checksFailing: return "xmark.circle.fill"
        case .conflicted:    return "exclamationmark.triangle.fill"
        case .draft:         return "pencil.circle"
        }
    }

    public var tint: ReadinessTint {
        switch self {
        case .ready:         return .green
        case .behind:        return .yellow
        case .blocked:       return .blue
        case .checksPending: return .yellow
        case .checksFailing: return .red
        case .conflicted:    return .orange
        case .draft:         return .gray
        }
    }

    /// Short phrase describing why the PR is in this state. Doubles as the
    /// accessibility label, so it must read sensibly on its own.
    public var label: String {
        switch self {
        case .ready:         return "Ready to merge"
        case .behind:        return "Behind base branch"
        case .blocked:       return "Waiting for review"
        case .checksPending: return "Checks running"
        case .checksFailing: return "Checks failing"
        case .conflicted:    return "Merge conflicts"
        case .draft:         return "Draft"
        }
    }

    /// Drafts are shown, but muted — they are not actionable yet.
    public var isDimmed: Bool { self == .draft }
}
