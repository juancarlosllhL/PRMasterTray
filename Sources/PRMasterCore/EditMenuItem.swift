import Foundation

/// Without a main menu there is nothing for the standard editing key
/// equivalents to hang on, so Cmd+V does nothing in any text field. Data here
/// so the set is testable; the app target turns it into an `NSMenu`.
public enum EditMenuItem: String, Sendable, Equatable, CaseIterable {
    case undo, redo, cut, copy, paste, selectAll

    public var title: String {
        switch self {
        case .undo:      return "Undo"
        case .redo:      return "Redo"
        case .cut:       return "Cut"
        case .copy:      return "Copy"
        case .paste:     return "Paste"
        case .selectAll: return "Select All"
        }
    }

    /// First-responder selectors AppKit already implements on every text view,
    /// sent with a nil target so they walk the responder chain.
    public var selectorName: String {
        switch self {
        case .undo:      return "undo:"
        case .redo:      return "redo:"
        case .cut:       return "cut:"
        case .copy:      return "copy:"
        case .paste:     return "paste:"
        case .selectAll: return "selectAll:"
        }
    }

    public var keyEquivalent: String {
        switch self {
        case .undo, .redo: return "z"
        case .cut:         return "x"
        case .copy:        return "c"
        case .paste:       return "v"
        case .selectAll:   return "a"
        }
    }

    public var requiresShift: Bool { self == .redo }

    public var isFollowedBySeparator: Bool { self == .redo }
}
