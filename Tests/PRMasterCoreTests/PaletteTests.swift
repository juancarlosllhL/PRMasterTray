import Foundation
import Testing
@testable import PRMasterCore

@Suite("Palette")
struct PaletteTests {

    /// What the palette is actually drawn on.
    ///
    /// The popover stays translucent, so the background moves with whatever is
    /// behind the window and there is no single value to test against. These are
    /// the extremes, measured off screenshots of the running app against
    /// deliberately hostile backdrops rather than hopeful ones.
    ///
    /// The material `PRListView` lays over the popover depends on the contrast
    /// mode, so the extreme does too. Dark standard uses the thinner
    /// `.regularMaterial` and lifted to #45494D behind a pure white window;
    /// everything else uses `.thickMaterial`, where light behind a pure black
    /// window fell to #DBDEE2 and dark behind a white one lifted to #3A3C3F.
    ///
    /// The last entry of each is a little past the measured extreme, so the suite
    /// is stricter than anything that can appear on screen. Every tint has to
    /// clear its floor against all three, not against the friendliest.
    static func backgrounds(
        _ appearance: AppearanceMode, _ background: PopoverBackground
    ) -> [RGB] {
        switch (background, appearance) {
        // Opaque: `windowBackgroundColor`, measured off the running app. The
        // extra entries are headroom in case it resolves differently on another
        // macOS version or display profile.
        case (.opaque, .light): return [.hex(0xFFFFFF), .hex(0xECECEC), .hex(0xE0E0E0)]
        case (.opaque, .dark):  return [.hex(0x1E1E1E), .hex(0x2B2B2B), .hex(0x3A3A3A)]
        // Liquid glass: the popover's own material, so the background follows
        // whatever is behind the window. The last entry of each is the measured
        // extreme against a deliberately hostile backdrop — a pure black window
        // behind the light theme, a pure white one behind the dark theme.
        case (.liquidGlass, .light): return [.hex(0xFFFFFF), .hex(0xECECEC), .hex(0xB9BDC1)]
        case (.liquidGlass, .dark):  return [.hex(0x1E1E1E), .hex(0x2B2B2B), .hex(0x5D5D5D)]
        }
    }

    /// What each configuration actually owes.
    ///
    /// Opaque owes the real thing: AA for standard, AAA for the two modes that
    /// exist because somebody asked for more than AA.
    ///
    /// Liquid glass cannot owe that and does not pretend to. On a background that
    /// ranges from #1E1E1E to #5D5D5D there is no coloured tint that holds 4.5:1
    /// and still reads as a colour — that is the trade the setting exists to let
    /// the user make. These are the ratios it does reach, pinned just under the
    /// measured values so the weaker configuration cannot quietly get weaker.
    static func minimumRatio(_ contrast: ContrastMode, _ background: PopoverBackground) -> Double {
        switch (background, contrast) {
        case (.opaque, .standard):        return 4.5
        case (.opaque, .increased):       return 7
        case (.opaque, .monochrome):      return 7
        case (.liquidGlass, .standard):   return 3.5
        case (.liquidGlass, .increased):  return 4.4
        case (.liquidGlass, .monochrome): return 6.5
        }
    }

    // MARK: - Contrast

    /// The load-bearing test of this whole feature: the ratio is computed here
    /// rather than copied from the plan, so editing a hex to something prettier
    /// fails the build instead of quietly shipping unreadable text.
    @Test(
        "every tint clears its threshold on every sampled background",
        arguments: ReadinessTint.allCases, ContrastMode.allCases
    )
    func clearsThreshold(tint: ReadinessTint, contrast: ContrastMode) {
        for appearance in AppearanceMode.allCases {
            let foreground = Palette.foreground(tint, appearance: appearance, contrast: contrast)

            for style in PopoverBackground.allCases {
                let floor = Self.minimumRatio(contrast, style)

                for background in Self.backgrounds(appearance, style) {
                    let ratio = Self.contrastRatio(foreground, background)
                    #expect(
                        ratio >= floor,
                        """
                        \(tint) in \(appearance)/\(contrast)/\(style) is \(ratio) \
                        against \(background), below the \(floor) floor
                        """
                    )
                }
            }
        }
    }

    /// The setting is only worth having if the two options actually differ, and
    /// the difference is the whole reason the footer warns about one of them.
    @Test("opaque is a stronger guarantee than liquid glass")
    func opaqueBeatsLiquidGlass() {
        for contrast in ContrastMode.allCases {
            #expect(
                Self.minimumRatio(contrast, .opaque)
                    > Self.minimumRatio(contrast, .liquidGlass)
            )
        }
    }

    // MARK: - Monochrome

    @Test("monochrome collapses every tint onto one value")
    func monochromeIsOneValue() {
        for appearance in AppearanceMode.allCases {
            let values = Set(ReadinessTint.allCases.map {
                Palette.foreground($0, appearance: appearance, contrast: .monochrome)
            })
            #expect(values.count == 1, "\(appearance) monochrome resolved to \(values.count) values")
        }
    }

    /// "Monochrome" has to mean it. A near-grey with a colour cast would still
    /// read as a hue to somebody who turned this on to be rid of hues.
    @Test("monochrome carries no hue at all")
    func monochromeHasNoHue() {
        for appearance in AppearanceMode.allCases {
            let value = Palette.foreground(.green, appearance: appearance, contrast: .monochrome)
            #expect(value.red == value.green)
            #expect(value.green == value.blue)
        }
    }

    // MARK: - Regression guards

    /// The dark palette is paler than anyone would pick by eye, for two reasons
    /// that compound, and both are easy to "tidy" away.
    ///
    /// Apple's own dark `systemBlue`, `systemRed` and `systemGray` measure
    /// 3.12:1, 3.34:1 and 3.96:1 on a dark background — under AA before anything
    /// else happens. And dark keeps a genuinely translucent material, so behind a
    /// light window the background lifts to #45494D rather than resting near
    /// #1E1E1E, which costs bright ink more contrast still.
    ///
    /// So this pins the values. Anything more saturated looks better in isolation
    /// and drops the row below AA in use.
    @Test("the dark palette stays pale rather than reverting to Apple's values")
    func darkStaysPale() {
        #expect(Palette.foreground(.blue, appearance: .dark, contrast: .standard) == .hex(0x8FC8FF))
        #expect(Palette.foreground(.red, appearance: .dark, contrast: .standard) == .hex(0xFFAFA8))
        #expect(Palette.foreground(.gray, appearance: .dark, contrast: .standard) == .hex(0xC7C7CC))
        #expect(Palette.foreground(.green, appearance: .dark, contrast: .standard) == .hex(0x5FE07F))
        #expect(Palette.foreground(.orange, appearance: .dark, contrast: .standard) == .hex(0xFFB84D))

        // Apple's dark system colours, none of which may come back.
        for (tint, apple) in [
            (ReadinessTint.blue, RGB.hex(0x0A84FF)),
            (.red, .hex(0xFF453A)),
            (.gray, .hex(0x98989D)),
            (.green, .hex(0x30D158)),
            (.orange, .hex(0xFF9F0A)),
        ] {
            #expect(Palette.foreground(tint, appearance: .dark, contrast: .standard) != apple)
        }
    }

    /// Increased contrast that is not actually more contrasted than standard
    /// would be a switch that does nothing, which is worse than no switch.
    @Test("increased contrast beats standard on every tint", arguments: ReadinessTint.allCases)
    func increasedBeatsStandard(tint: ReadinessTint) {
        for appearance in AppearanceMode.allCases {
            let background = Self.backgrounds(appearance, .opaque)[0]
            let standard = Self.contrastRatio(
                Palette.foreground(tint, appearance: appearance, contrast: .standard), background
            )
            let increased = Self.contrastRatio(
                Palette.foreground(tint, appearance: appearance, contrast: .increased), background
            )
            #expect(increased > standard, "\(tint) in \(appearance)")
        }
    }

    // MARK: - WCAG

    /// WCAG 2.x relative luminance and contrast ratio, straight from the spec.
    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let first = relativeLuminance(a)
        let second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func relativeLuminance(_ colour: RGB) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.red)
            + 0.7152 * linear(colour.green)
            + 0.0722 * linear(colour.blue)
    }

    /// Guards the helper the rest of this suite trusts: black on white is the
    /// one contrast ratio with a known answer.
    @Test("the ratio helper matches the WCAG reference values")
    func helperIsCorrect() {
        #expect(abs(Self.contrastRatio(.hex(0x000000), .hex(0xFFFFFF)) - 21) < 0.01)
        #expect(abs(Self.contrastRatio(.hex(0xFFFFFF), .hex(0xFFFFFF)) - 1) < 0.01)
        // WebAIM's worked example for #808080 on white.
        #expect(abs(Self.contrastRatio(.hex(0x808080), .hex(0xFFFFFF)) - 3.95) < 0.02)
    }

    @Test("hex unpacks into components")
    func hexUnpacks() {
        let value = RGB.hex(0x336699)
        #expect(abs(value.red - 0x33 / 255.0) < 0.0001)
        #expect(abs(value.green - 0x66 / 255.0) < 0.0001)
        #expect(abs(value.blue - 0x99 / 255.0) < 0.0001)
    }
}
