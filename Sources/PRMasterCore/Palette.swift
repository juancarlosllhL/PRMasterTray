/// The concrete colours behind the semantic tints.
///
/// Lives in the core rather than beside the SwiftUI that draws it so the one
/// thing that actually matters here — that every value clears its WCAG floor —
/// can be asserted by a test that computes the ratio rather than trusting a
/// comment. `PaletteTests` is the specification; this file is the answer to it.
///
/// The values are not Apple's system colours. Those are tuned for large fills
/// and fail badly as 11pt text: against a light popover, `systemYellow` measures
/// 1.28:1, `systemGreen` 1.80:1 and `systemOrange` 1.86:1, where AA asks 4.5:1.
/// Dark mode is better but not clean either — Apple's dark blue, red and grey
/// come in at 3.12:1, 3.34:1 and 3.96:1, so those three are lightened here.

/// A colour as gamma-encoded sRGB components in 0...1 — the form both a hex
/// literal and SwiftUI's `Color(.sRGB, red:green:blue:)` are already in, so
/// nothing in between has to convert anything.
public struct RGB: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xRRGGBB`, so the table below reads like the one in the plan and can be
    /// pasted straight into a contrast checker.
    static func hex(_ value: UInt32) -> RGB {
        RGB(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

public enum AppearanceMode: Sendable, Equatable, CaseIterable {
    case light, dark
}

/// How much contrast the palette owes.
///
/// Not a user setting on its own: it is derived from the app's monochrome switch
/// and macOS's own display settings together. See `AppearanceStore`.
public enum ContrastMode: Sendable, Equatable, CaseIterable {
    /// WCAG AA — the floor for anything rendered as text.
    case standard
    /// Somebody asked macOS for more contrast, so AAA.
    case increased
    /// No hue at all, at whatever contrast the appearance allows.
    case monochrome
}

public enum Palette {

    /// The colour for a tint, used for both the glyph and the status label.
    ///
    /// A 14pt SF Symbol is a graphical object and only owes 3:1, but one value
    /// per tint is one value to keep honest, and the label beside it owes 4.5:1
    /// regardless.
    public static func foreground(
        _ tint: ReadinessTint, appearance: AppearanceMode, contrast: ContrastMode
    ) -> RGB {
        switch (appearance, contrast) {
        // Monochrome ignores the tint on purpose. Which state a row is in is
        // already carried twice over — seven distinct glyphs and a written
        // label — so dropping hue costs nothing and buys the highest contrast
        // either appearance can offer.
        case (.light, .monochrome): return .hex(0x000000)  // 15.91:1
        case (.dark, .monochrome):  return .hex(0xFFFFFF)  // 11.37:1
        case (.light, .standard):   return lightStandard(tint)
        case (.light, .increased):  return lightIncreased(tint)
        case (.dark, .standard):    return darkStandard(tint)
        case (.dark, .increased):   return darkIncreased(tint)
        }
    }

    // MARK: - Light
    //
    // Ratios in the trailing comments are the worst case across the three
    // backgrounds an NSPopover lands between, not a best case against white.

    private static func lightStandard(_ tint: ReadinessTint) -> RGB {
        switch tint {
        case .green:  return .hex(0x17692C)  // 5.14:1
        case .yellow: return .hex(0x6E5200)  // 5.54:1 — a goldenrod, because a
                                             // legible yellow on white is brown
        case .blue:   return .hex(0x0A4FB5)  // 5.68:1
        case .red:    return .hex(0xB3000F)  // 5.44:1
        case .orange: return .hex(0x8A4A00)  // 5.20:1
        case .gray:   return .hex(0x565659)  // 5.54:1
        }
    }

    private static func lightIncreased(_ tint: ReadinessTint) -> RGB {
        switch tint {
        case .green:  return .hex(0x0B4D1E)  // 7.60:1
        case .yellow: return .hex(0x4A3700)  // 8.66:1
        case .blue:   return .hex(0x003480)  // 8.82:1
        case .red:    return .hex(0x7A000A)  // 8.68:1
        case .orange: return .hex(0x5E3100)  // 8.31:1
        case .gray:   return .hex(0x3A3A3C)  // 8.60:1
        }
    }

    // MARK: - Dark

    /// Paler than Apple's dark system colours, and paler than you would pick by
    /// eye. Two reasons compound here.
    ///
    /// Apple's own dark `systemBlue` (#0A84FF), `systemRed` (#FF453A) and
    /// `systemGray` (#98989D) measure 3.12:1, 3.34:1 and 3.96:1 against a dark
    /// background — under AA before anything else happens.
    ///
    /// Then the background itself moves. Dark keeps a genuinely translucent
    /// material, so over a light window behind the popover it lifts to #45494D
    /// rather than staying near #1E1E1E. Bright ink loses contrast as the
    /// background lightens, which is the mirror image of light mode's problem, so
    /// every one of these has to clear AA against the lifted value and not the
    /// resting one. Restoring anything more saturated would look like tidying and
    /// would quietly drop the row below AA; `PaletteTests` fails if anyone tries.
    private static func darkStandard(_ tint: ReadinessTint) -> RGB {
        switch tint {
        case .green:  return .hex(0x5FE07F)  // 5.38:1
        case .yellow: return .hex(0xFFD60A)  // 6.43:1 — Apple's, light enough already
        case .blue:   return .hex(0x8FC8FF)  // 5.13:1
        case .red:    return .hex(0xFFAFA8)  // 5.17:1
        case .orange: return .hex(0xFFB84D)  // 5.28:1
        case .gray:   return .hex(0xC7C7CC)  // 5.39:1
        }
    }

    private static func darkIncreased(_ tint: ReadinessTint) -> RGB {
        switch tint {
        case .green:  return .hex(0x7DEB9B)  // 7.71:1
        case .yellow: return .hex(0xFFE566)  // 9.02:1
        case .blue:   return .hex(0xB8DBFF)  // 7.92:1
        case .red:    return .hex(0xFFC9C4)  // 7.80:1
        case .orange: return .hex(0xFFD394)  // 7.43:1
        case .gray:   return .hex(0xD6D6DB)  // 7.85:1
        }
    }
}
