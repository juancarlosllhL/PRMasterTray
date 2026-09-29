/// Semantic colour for a readiness state. Named rather than concrete so the
/// mapping stays in the testable core and only the SwiftUI layer knows about
/// actual `Color` values.
/// `CaseIterable` so `PaletteTests` can assert the contrast floor across every
/// tint rather than across the ones somebody remembered to list.
public enum ReadinessTint: Sendable, Equatable, CaseIterable {
    case green, yellow, blue, red, orange, gray
}

extension Readiness {

    /// Glyph shown at the leading edge of each row.
    public var glyph: StatusGlyph {
        switch self {
        case .ready:              return .ready
        case .behind:             return .behind
        case .quillComments:      return .quill
        case .unresolvedComments: return .comments
        case .blocked:            return .waiting
        case .checksPending:      return .pending
        case .checksFailing:      return .failing
        case .conflicted:         return .conflicted
        case .draft:              return .draft
        }
    }

    public var tint: ReadinessTint {
        switch self {
        case .ready:         return .green
        case .behind:        return .yellow
        // Orange, as `ReviewState.changesRequested`: the author has to act.
        case .quillComments, .unresolvedComments: return .orange
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
        case .quillComments: return "Quill comments"
        case .unresolvedComments: return "Unresolved comments"
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
