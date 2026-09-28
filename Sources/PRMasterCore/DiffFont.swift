import Foundation

public enum DiffFont {

    /// The family to draw with, or nil for the system font when nothing was
    /// chosen or the chosen family has since been uninstalled.
    public static func resolve(stored: String?, installed: [String]) -> String? {
        stored.flatMap { installed.contains($0) ? $0 : nil }
    }

    public static func sorted(_ families: [String]) -> [String] {
        Array(Set(families)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
