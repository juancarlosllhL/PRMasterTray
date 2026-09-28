import Foundation
import Testing
@testable import PRMasterCore

@MainActor
@Suite("DiffFont")
struct DiffFontTests {

    @Test("nothing chosen means the system font")
    func defaultIsSystem() {
        #expect(AppearanceStore(preferences: MemoryPreferences()).diffFontFamily == nil)
    }

    @Test("choosing a font writes it through, and clearing it forgets it")
    func writesThrough() {
        let preferences = MemoryPreferences()
        let store = AppearanceStore(preferences: preferences)
        store.diffFontFamily = "JetBrains Mono"
        #expect(preferences.diffFontFamily() == "JetBrains Mono")
        store.diffFontFamily = nil
        #expect(preferences.diffFontFamily() == nil)
    }

    @Test("a new store opens with the font chosen last time")
    func readAtLaunch() {
        let preferences = MemoryPreferences()
        preferences.setDiffFontFamily("Menlo")
        #expect(AppearanceStore(preferences: preferences).diffFontFamily == "Menlo")
    }

    @Test("the choice survives a round trip through UserDefaults, and clearing removes the key")
    func userDefaultsRoundTrip() {
        let name = "DiffFontTests.roundTrip"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = UserDefaultsPreferences(defaults: defaults)
        #expect(preferences.diffFontFamily() == nil)
        preferences.setDiffFontFamily("Menlo")
        #expect(UserDefaultsPreferences(defaults: defaults).diffFontFamily() == "Menlo")
        preferences.setDiffFontFamily(nil)
        #expect(defaults.object(forKey: "diffFontFamily") == nil)
    }

    @Test("a chosen font that is still installed is used")
    func installedIsUsed() {
        #expect(DiffFont.resolve(stored: "Menlo", installed: ["Menlo", "Monaco"]) == "Menlo")
    }

    @Test("a chosen font that was uninstalled falls back to the system font")
    func uninstalledFallsBack() {
        #expect(DiffFont.resolve(stored: "Fira Code", installed: ["Menlo"]) == nil)
        #expect(DiffFont.resolve(stored: nil, installed: ["Menlo"]) == nil)
    }

    @Test("the list is sorted the way a person reads it, without duplicates")
    func listOrder() {
        #expect(DiffFont.sorted(["monaco", "Menlo", "Andale Mono", "Menlo"]) == ["Andale Mono", "Menlo", "monaco"])
    }
}
