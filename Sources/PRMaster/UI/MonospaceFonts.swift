import AppKit
import PRMasterCore

@MainActor
enum MonospaceFonts {

    /// Installed families that draw every character at one width. Some fonts
    /// never set the monospace trait, so equal advances count as well.
    static func installed() -> [String] {
        DiffFont.sorted(NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") && isMonospaced($0) })
    }

    static func font(family: String, size: CGFloat, bold: Bool = false) -> NSFont? {
        NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: 5, size: size)
    }

    private static func isMonospaced(_ family: String) -> Bool {
        guard let font = font(family: family, size: 12) else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
        let widths = ["i", "W", "0", "."].map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        return widths.allSatisfy { abs($0 - widths[0]) < 0.01 }
    }
}
