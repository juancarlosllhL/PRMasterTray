import Foundation

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case context, added, removed
    }

    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String
    public let noNewlineAtEnd: Bool

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String, noNewlineAtEnd: Bool = false) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.noNewlineAtEnd = noNewlineAtEnd
    }

    func withNoNewlineAtEnd() -> DiffLine {
        DiffLine(kind: kind, oldNumber: oldNumber, newNumber: newNumber, text: text, noNewlineAtEnd: true)
    }
}

public struct Hunk: Sendable, Equatable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// The enclosing declaration git prints after the second `@@`, or empty.
    public let context: String
    public let lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, context: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.context = context
        self.lines = lines
    }
}

public enum OmissionReason: Sendable, Equatable {
    /// No patch but counted changes: GitHub left it out for size.
    case tooLarge
    /// No patch and nothing counted: binary, empty, mode-only or a pure rename.
    case noTextChanges
    case unparseable
}

public enum DiffContent: Sendable, Equatable {
    case hunks([Hunk])
    case omitted(OmissionReason)
}

/// GitHub's `FileViewedState`.
public enum ViewedState: String, Sendable, Equatable {
    case viewed = "VIEWED"
    case unviewed = "UNVIEWED"
    /// Viewed, then changed by a later push.
    case dismissed = "DISMISSED"
}

public struct DiffFile: Sendable, Equatable, Identifiable {
    /// The REST `status` values.
    public enum Change: String, Sendable, Equatable {
        case added, removed, modified, renamed, copied, changed, unchanged
    }

    public var id: String { path }
    public let path: String
    public let previousPath: String?
    public let change: Change
    public let additions: Int
    public let deletions: Int
    public let content: DiffContent
    public var viewed: ViewedState

    public init(
        path: String, previousPath: String?, change: Change,
        additions: Int, deletions: Int, content: DiffContent, viewed: ViewedState = .unviewed
    ) {
        self.path = path
        self.previousPath = previousPath
        self.change = change
        self.additions = additions
        self.deletions = deletions
        self.content = content
        self.viewed = viewed
    }
}
