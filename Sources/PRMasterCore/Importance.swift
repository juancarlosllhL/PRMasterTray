import Foundation

/// How closely a human must review a changed line, least first.
public enum Importance: Int, Sendable, Comparable, CaseIterable {
    case glue, routine, logic, sensitive

    /// The nearest level. Uncertainty is drawn as hatching, so it is not folded in here.
    public init(score: Double) {
        guard score.isFinite else {
            self = .sensitive
            return
        }
        self = Importance(rawValue: Int(min(max(score, 0), 3).rounded())) ?? .sensitive
    }

    public static func < (a: Importance, b: Importance) -> Bool { a.rawValue < b.rawValue }
}

/// One answer from Jev: where a line falls on the four levels, and how sure it is.
public struct LineHeat: Sendable, Equatable {
    /// The bottom quarter of line confidences measured on real diffs.
    public static let uncertainBelow = 0.35

    /// From 0, glue, to 3, sensitive.
    public let score: Double
    public let confidence: Double?

    public init(score: Double, confidence: Double?) {
        self.score = score.isFinite ? min(max(score, 0), 3) : 3
        self.confidence = confidence
    }

    public var level: Importance { Importance(score: score) }
    public var isUncertain: Bool { (confidence ?? 1) < Self.uncertainBelow }
}
