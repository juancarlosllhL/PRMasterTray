import Testing
@testable import PRMasterCore

@Suite("Contrast resolution")
struct ContrastResolutionTests {

    /// The whole truth table, not a sample of it. Three booleans is eight rows,
    /// and the interesting ones are the disagreements: the app switch off while
    /// macOS asks for no colour, and both contrast requests arriving at once.
    @Test("the switch and the system settings combine", arguments: [
        // monochrome, differentiateWithoutColor, increasedContrast, expected
        (false, false, false, ContrastMode.standard),
        (false, false, true, ContrastMode.increased),
        (false, true, false, ContrastMode.monochrome),
        (false, true, true, ContrastMode.monochrome),
        (true, false, false, ContrastMode.monochrome),
        (true, false, true, ContrastMode.monochrome),
        (true, true, false, ContrastMode.monochrome),
        (true, true, true, ContrastMode.monochrome),
    ])
    func truthTable(
        monochrome: Bool,
        differentiateWithoutColor: Bool,
        increasedContrast: Bool,
        expected: ContrastMode
    ) {
        let resolved = ContrastMode.resolve(
            monochromeEnabled: monochrome,
            systemDifferentiateWithoutColor: differentiateWithoutColor,
            systemIncreasedContrast: increasedContrast
        )
        #expect(resolved == expected)
    }

    /// The point of OR-ing rather than replacing: somebody who has already told
    /// macOS they cannot use colour must not have to find this app's switch too.
    @Test("the system can turn monochrome on while the app switch is off")
    func systemAloneIsEnough() {
        #expect(ContrastMode.resolve(
            monochromeEnabled: false,
            systemDifferentiateWithoutColor: true,
            systemIncreasedContrast: false
        ) == .monochrome)
    }

    /// Monochrome is the stronger request — it already carries the highest
    /// contrast either appearance can offer, so increased must not dilute it.
    @Test("monochrome wins when both are asked for")
    func monochromeOutranksIncreased() {
        #expect(ContrastMode.resolve(
            monochromeEnabled: true,
            systemDifferentiateWithoutColor: false,
            systemIncreasedContrast: true
        ) == .monochrome)
    }

    @Test("nothing asked for leaves the standard palette")
    func defaultIsStandard() {
        #expect(ContrastMode.resolve(
            monochromeEnabled: false,
            systemDifferentiateWithoutColor: false,
            systemIncreasedContrast: false
        ) == .standard)
    }
}

@Suite("App theme")
struct AppThemeTests {

    /// Raw values are a storage contract — they are what lands in UserDefaults,
    /// so renaming a case would silently reset everybody to System.
    @Test("raw values are the stored strings", arguments: [
        (AppTheme.system, "system"),
        (AppTheme.light, "light"),
        (AppTheme.dark, "dark"),
    ])
    func rawValues(theme: AppTheme, raw: String) {
        #expect(theme.rawValue == raw)
        #expect(AppTheme(rawValue: raw) == theme)
    }

    @Test("there are exactly three themes to offer")
    func caseCount() {
        #expect(AppTheme.allCases.count == 3)
    }

    @Test("an unrecognised string is not a theme")
    func unknownIsNil() {
        #expect(AppTheme(rawValue: "solarized") == nil)
    }
}
