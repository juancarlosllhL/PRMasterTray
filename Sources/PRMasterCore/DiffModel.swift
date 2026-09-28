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
