import Foundation

/// What a diff row is painted as. Headers share one tint.
public enum DiffLineTint: Sendable, Equatable, CaseIterable {
    case context, added, removed, header
}

/// Diff colours for the review window. Worst text ratios against any row:
/// standard 11.64:1, increased 13.76:1, monochrome 12.08:1. Syntax colours are floored at 4.5:1 or 7:1.
extension Palette {

    public static func diffText(appearance: AppearanceMode, contrast: ContrastMode) -> RGB {
        switch (appearance, contrast) {
        case (.light, .standard): return .hex(0x1F2328)
        case (.light, _): return .hex(0x000000)
        case (.dark, .standard): return .hex(0xE6EDF3)
        case (.dark, _): return .hex(0xFFFFFF)
        }
    }

    public static func diffBackground(
        _ tint: DiffLineTint, appearance: AppearanceMode, contrast: ContrastMode
    ) -> RGB {
        switch (appearance, contrast == .monochrome, tint) {
        case (.light, false, .context): return .hex(0xFFFFFF)
        case (.light, false, .added): return .hex(0xE6FFEC)
        case (.light, false, .removed): return .hex(0xFFEBE9)
        case (.light, false, .header): return .hex(0xF6F8FA)
        case (.light, true, .context): return .hex(0xFFFFFF)
        case (.light, true, .added): return .hex(0xF0F0F0)
        case (.light, true, .removed): return .hex(0xE4E4E4)
        case (.light, true, .header): return .hex(0xEBEBEB)
        case (.dark, false, .context): return .hex(0x1E1E1E)
        case (.dark, false, .added): return .hex(0x203124)
        case (.dark, false, .removed): return .hex(0x342322)
        case (.dark, false, .header): return .hex(0x2B2B2B)
        case (.dark, true, .context): return .hex(0x1E1E1E)
        case (.dark, true, .added): return .hex(0x2A2A2A)
        case (.dark, true, .removed): return .hex(0x363636)
        case (.dark, true, .header): return .hex(0x262626)
        }
    }
}

extension SyntaxTheme {
    /// Monochrome paints no syntax colour, so which theme it reads with does not matter.
    public init(appearance: AppearanceMode, contrast: ContrastMode) {
        switch (appearance, contrast) {
        case (.light, .increased): self = .lightHighContrast
        case (.dark, .increased): self = .darkHighContrast
        case (.light, _): self = .light
        case (.dark, _): self = .dark
        }
    }
}

extension Palette {

    /// A theme colour as the row shows it: the theme's own unless it falls under the diff floor.
    public static func syntax(
        _ colour: RGB, tint: DiffLineTint, appearance: AppearanceMode, contrast: ContrastMode
    ) -> RGB {
        readable(
            colour, on: diffBackground(tint, appearance: appearance, contrast: contrast),
            floor: contrast == .standard ? 4.5 : 7
        )
    }

    /// Mixing toward black or white keeps the hue, and the search stops at the least mix that passes.
    static func readable(_ colour: RGB, on background: RGB, floor: Double) -> RGB {
        guard colour.contrast(with: background) < floor else { return colour }
        let target: RGB = background.luminance > 0.179 ? .hex(0x000000) : .hex(0xFFFFFF)
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if colour.mixed(with: target, by: middle).contrast(with: background) >= floor {
                high = middle
            } else {
                low = middle
            }
        }
        return colour.mixed(with: target, by: high)
    }
}

extension RGB {
    /// WCAG 2.x relative luminance.
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: RGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    func mixed(with other: RGB, by amount: Double) -> RGB {
        RGB(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }
}

extension Palette {

    /// The review-importance stripe in a changed line's gutter. Every colour
    /// clears 3:1 against every line background, the WCAG floor for graphics.
    public static func heatStripe(_ level: Importance, appearance: AppearanceMode, contrast: ContrastMode) -> RGB {
        switch (appearance, contrast, level) {
        case (.light, .monochrome, _): return .hex(0x595959)
        case (.dark, .monochrome, _): return .hex(0xA6A6A6)
        case (.light, .standard, .glue): return .hex(0x6E7781)
        case (.light, .standard, .routine): return .hex(0x0969DA)
        case (.light, .standard, .logic): return .hex(0x9A6700)
        case (.light, .standard, .sensitive): return .hex(0xCF222E)
        case (.light, .increased, .glue): return .hex(0x57606A)
        case (.light, .increased, .routine): return .hex(0x0550AE)
        case (.light, .increased, .logic): return .hex(0x7D4E00)
        case (.light, .increased, .sensitive): return .hex(0xA40E26)
        case (.dark, .standard, .glue): return .hex(0x8B949E)
        case (.dark, .standard, .routine): return .hex(0x4493F8)
        case (.dark, .standard, .logic): return .hex(0xD29922)
        case (.dark, .standard, .sensitive): return .hex(0xF85149)
        case (.dark, .increased, .glue): return .hex(0xB7BDC8)
        case (.dark, .increased, .routine): return .hex(0x71B7FF)
        case (.dark, .increased, .logic): return .hex(0xF0B72F)
        case (.dark, .increased, .sensitive): return .hex(0xFF6A69)
        }
    }

    /// Points, from 1.5 at glue to 5 at sensitive. The exact score, where colour only shows its level.
    public static func heatStripeWidth(score: Double) -> Double {
        1.5 + min(max(score, 0), 3) * 3.5 / 3
    }
}
