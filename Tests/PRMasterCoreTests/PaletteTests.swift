import Foundation
import Testing
@testable import PRMasterCore

@Suite("Palette")
struct PaletteTests {

    /// What the palette is actually drawn on.
    ///
    /// `PRListView` backs the popover with `.thickMaterial`, so the background is
    /// a real translucent system material and does move with whatever is behind
    /// the window — but far less than the popover's own material did. That matters
    /// because the bare popover material rendered the light case at #B9BDC1 over a
    /// dark window, which put every tint between 3.6:1 and 4.0:1. `.thickMaterial`
    /// narrows the range enough for a floor to mean something.
    ///
    /// The last entry of each is the extreme, measured off screenshots of the
    /// running app against a deliberately hostile backdrop: a pure black window
    /// behind the light theme rendered #DBDEE2, and a pure white one behind the
    /// dark theme rendered #3A3C3F. The values here are a little past both, so the
    /// suite is stricter than anything that can actually appear on screen. Every
    /// tint has to clear its floor against all three, not the friendliest.
    static func backgrounds(_ appearance: AppearanceMode) -> [RGB] {
        switch appearance {
        case .light: return [.hex(0xFFFFFF), .hex(0xECECEC), .hex(0xD8DBDF)]
        case .dark:  return [.hex(0x1E1E1E), .hex(0x2B2B2B), .hex(0x3E4043)]
        }
    }

    /// AA for normal text. `.increased` and `.monochrome` exist precisely
    /// because somebody asked for more than that, so they owe AAA.
    static func minimumRatio(_ contrast: ContrastMode) -> Double {
        switch contrast {
        case .standard:   return 4.5
        case .increased:  return 7
        case .monochrome: return 7
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
            let floor = Self.minimumRatio(contrast)

            for background in Self.backgrounds(appearance) {
                let ratio = Self.contrastRatio(foreground, background)
                #expect(
                    ratio >= floor,
                    """
                    \(tint) in \(appearance)/\(contrast) is \(ratio) against \
                    \(background), below the \(floor) floor
                    """
                )
            }
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

    /// Apple's own dark `systemBlue`, `systemRed` and `systemGray` measure
    /// 3.12:1, 3.34:1 and 3.96:1 against the darkest background above — all
    /// below AA. These are deliberately lighter, and "restoring" Apple's
    /// values would undo the fix while looking like a tidy-up.
    @Test("dark blue, red and grey stay lightened rather than Apple's values")
    func darkOverridesStayLightened() {
        #expect(Palette.foreground(.blue, appearance: .dark, contrast: .standard) == .hex(0x64B5FF))
        #expect(Palette.foreground(.red, appearance: .dark, contrast: .standard) == .hex(0xFF9188))
        #expect(Palette.foreground(.gray, appearance: .dark, contrast: .standard) == .hex(0xAEAEB2))

        for tint in [ReadinessTint.blue, .red, .gray] {
            let apple: RGB = switch tint {
            case .blue: .hex(0x0A84FF)
            case .red:  .hex(0xFF453A)
            default:    .hex(0x98989D)
            }
            #expect(Palette.foreground(tint, appearance: .dark, contrast: .standard) != apple)
        }
    }

    /// Increased contrast that is not actually more contrasted than standard
    /// would be a switch that does nothing, which is worse than no switch.
    @Test("increased contrast beats standard on every tint", arguments: ReadinessTint.allCases)
    func increasedBeatsStandard(tint: ReadinessTint) {
        for appearance in AppearanceMode.allCases {
            let background = Self.backgrounds(appearance)[0]
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
