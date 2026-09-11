import Foundation

public enum TitleOverflow {

    /// Text measurement lands a fraction above the space it was given even when
    /// it fits, which would arm a tooltip on rows that read perfectly well.
    static let tolerance = 0.5

    public static func isTruncated(ideal: Double, shown: Double) -> Bool {
        guard ideal > 0, shown > 0 else { return false }
        return ideal - shown > tolerance
    }
}
