import Foundation
import Testing
@testable import PRMasterCore

/// The diff window is opaque and paints every row itself, so unlike the
/// popover each pair of text and background is exactly known.
@Suite("Diff palette")
struct DiffPaletteTests {

    @Test(
        "diff text clears the opaque floor on every line background",
        arguments: DiffLineTint.allCases, ContrastMode.allCases
    )
    func textOnBackground(tint: DiffLineTint, contrast: ContrastMode) {
        for appearance in AppearanceMode.allCases {
            let ratio = PaletteTests.contrastRatio(
                Palette.diffText(appearance: appearance, contrast: contrast),
                Palette.diffBackground(tint, appearance: appearance, contrast: contrast)
            )
            #expect(
                ratio >= PaletteTests.minimumRatio(contrast, .opaque),
                "\(tint) in \(appearance)/\(contrast) is \(ratio)"
            )
        }
    }

    @Test(
        "every colour the bundled themes use clears the opaque floor once made readable",
        arguments: [ContrastMode.standard, .increased]
    )
    func syntaxOnBackground(contrast: ContrastMode) async {
        for appearance in AppearanceMode.allCases {
            let theme = SyntaxTheme(appearance: appearance, contrast: contrast)
            let colours = await ShikiScript.highlighter.colours(of: theme)
            #expect(colours.count > 5)
            for colour in colours {
                for tint in DiffLineTint.allCases {
                    let shown = Palette.syntax(colour, tint: tint, appearance: appearance, contrast: contrast)
                    let ratio = PaletteTests.contrastRatio(
                        shown, Palette.diffBackground(tint, appearance: appearance, contrast: contrast)
                    )
                    #expect(
                        ratio >= PaletteTests.minimumRatio(contrast, .opaque),
                        "\(colour) from \(theme) on \(tint) is \(ratio)"
                    )
                    #expect(hueDistance(colour, shown) <= 2, "\(colour) from \(theme) drifted to \(shown)")
                }
            }
        }
    }

    @Test("a colour that already reads is shown as the theme has it")
    func readableColourUnchanged() {
        let white = RGB.hex(0xFFFFFF)
        #expect(Palette.readable(.hex(0x0550AE), on: white, floor: 4.5) == .hex(0x0550AE))
        #expect(Palette.readable(.hex(0x000000), on: white, floor: 7) == .hex(0x000000))
    }

    @Test("a faint colour is moved only as far as the floor needs")
    func faintColourMovesJustEnough() {
        let background = RGB.hex(0xFFEBE9)
        let comment = RGB.hex(0x6E7781)
        let shown = Palette.readable(comment, on: background, floor: 4.5)
        let ratio = PaletteTests.contrastRatio(shown, background)
        #expect(ratio >= 4.5 && ratio < 4.6, "\(ratio)")
    }

    @Test("dark rows lighten a colour, light rows darken it")
    func direction() {
        let grey = RGB.hex(0x777777)
        #expect(Palette.readable(grey, on: .hex(0x1E1E1E), floor: 7).red > grey.red)
        #expect(Palette.readable(grey, on: .hex(0xFFFFFF), floor: 7).red < grey.red)
    }

    @Test("increased contrast reads with GitHub's high-contrast themes; the rest with the defaults")
    func themeChoice() {
        #expect(SyntaxTheme(appearance: .light, contrast: .standard) == .light)
        #expect(SyntaxTheme(appearance: .dark, contrast: .standard) == .dark)
        #expect(SyntaxTheme(appearance: .light, contrast: .increased) == .lightHighContrast)
        #expect(SyntaxTheme(appearance: .dark, contrast: .increased) == .darkHighContrast)
        #expect(SyntaxTheme(appearance: .dark, contrast: .monochrome) == .dark)
    }

    @Test("monochrome backgrounds carry no hue", arguments: DiffLineTint.allCases)
    func monochromeIsGrey(tint: DiffLineTint) {
        for appearance in AppearanceMode.allCases {
            let colour = Palette.diffBackground(tint, appearance: appearance, contrast: .monochrome)
            #expect(colour.red == colour.green && colour.green == colour.blue, "\(tint) in \(appearance)")
        }
    }

    @Test("added and removed lines never share a background", arguments: ContrastMode.allCases)
    func addedDiffersFromRemoved(contrast: ContrastMode) {
        for appearance in AppearanceMode.allCases {
            #expect(
                Palette.diffBackground(.added, appearance: appearance, contrast: contrast)
                    != Palette.diffBackground(.removed, appearance: appearance, contrast: contrast)
            )
        }
    }
}

/// Degrees around the colour wheel; greys have no hue and count as zero.
private func hueDistance(_ a: RGB, _ b: RGB) -> Double {
    guard let first = hue(a), let second = hue(b) else { return 0 }
    let distance = abs(first - second)
    return min(distance, 360 - distance)
}

private func hue(_ colour: RGB) -> Double? {
    let high = max(colour.red, colour.green, colour.blue), low = min(colour.red, colour.green, colour.blue)
    let range = high - low
    guard range > 0.02 else { return nil }
    let sector: Double
    switch high {
    case colour.red: sector = (colour.green - colour.blue) / range
    case colour.green: sector = (colour.blue - colour.red) / range + 2
    default: sector = (colour.red - colour.green) / range + 4
    }
    return (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
}
