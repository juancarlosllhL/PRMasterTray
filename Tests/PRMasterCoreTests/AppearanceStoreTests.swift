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

@Suite("Appearance store")
@MainActor
struct AppearanceStoreTests {

    /// Every control in the settings window writes straight through, so there is
    /// no Save button and nothing to undo but the switch itself. That only holds
    /// if the setter actually persists.
    @Test("setting the theme persists it")
    func themePersists() {
        let preferences = MemoryPreferences()
        let store = AppearanceStore(preferences: preferences)

        store.theme = .dark
        #expect(preferences.theme() == .dark)
    }

    @Test("setting monochrome persists it")
    func monochromePersists() {
        let preferences = MemoryPreferences()
        let store = AppearanceStore(preferences: preferences)

        store.monochromeEnabled = true
        #expect(preferences.monochromeEnabled() == true)
    }

    /// Switching back off has to persist too — the failure mode of the naive
    /// `bool(forKey:)` version is that it silently does not.
    @Test("switching monochrome back off persists as well")
    func monochromeOffPersists() {
        let preferences = MemoryPreferences(monochrome: true)
        let store = AppearanceStore(preferences: preferences)

        store.monochromeEnabled = false
        #expect(preferences.monochromeEnabled() == false)
    }

    @Test("a stored appearance is restored on launch", arguments: AppTheme.allCases)
    func restoresOnInit(theme: AppTheme) {
        let store = AppearanceStore(
            preferences: MemoryPreferences(theme: theme, monochrome: true)
        )

        #expect(store.theme == theme)
        #expect(store.monochromeEnabled == true)
    }

    /// Reading defaults must not write them back — a launch that never touched a
    /// setting should leave the key absent, so the fallback keeps applying.
    @Test("reading the defaults does not persist them")
    func initDoesNotWrite() {
        let preferences = MemoryPreferences()
        _ = AppearanceStore(preferences: preferences)

        #expect(preferences.theme() == .system)
        #expect(preferences.monochromeEnabled() == false)
    }

    @Test("setting the popover background persists it")
    func backgroundPersists() {
        let preferences = MemoryPreferences()
        let store = AppearanceStore(preferences: preferences)

        store.popoverBackground = .opaque
        #expect(preferences.popoverBackground() == .opaque)
    }

    @Test("a stored popover background is restored on launch",
          arguments: PopoverBackground.allCases)
    func backgroundRestores(style: PopoverBackground) {
        let store = AppearanceStore(preferences: MemoryPreferences(background: style))
        #expect(store.popoverBackground == style)
    }

    // MARK: - Contrast

    /// The convenience the view actually calls: the store supplies its own
    /// switch, the caller supplies what macOS says.
    @Test("the store resolves contrast from its own switch")
    func resolvesFromOwnSwitch() {
        let store = AppearanceStore(preferences: MemoryPreferences(monochrome: true))

        #expect(store.resolvedContrast(
            systemDifferentiateWithoutColor: false, systemIncreasedContrast: false
        ) == .monochrome)
    }

    @Test("the store still honours the system with its own switch off")
    func honoursSystemWhenOff() {
        let store = AppearanceStore(preferences: MemoryPreferences(monochrome: false))

        #expect(store.resolvedContrast(
            systemDifferentiateWithoutColor: true, systemIncreasedContrast: false
        ) == .monochrome)
        #expect(store.resolvedContrast(
            systemDifferentiateWithoutColor: false, systemIncreasedContrast: true
        ) == .increased)
        #expect(store.resolvedContrast(
            systemDifferentiateWithoutColor: false, systemIncreasedContrast: false
        ) == .standard)
    }

    /// Flipping the switch has to change what the palette resolves to without
    /// rebuilding the store, or the setting would only take effect on relaunch.
    @Test("flipping the switch changes resolution immediately")
    func flippingTakesEffect() {
        let store = AppearanceStore(preferences: MemoryPreferences())
        #expect(store.resolvedContrast(
            systemDifferentiateWithoutColor: false, systemIncreasedContrast: false
        ) == .standard)

        store.monochromeEnabled = true
        #expect(store.resolvedContrast(
            systemDifferentiateWithoutColor: false, systemIncreasedContrast: false
        ) == .monochrome)
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
