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
