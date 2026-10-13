import Foundation
import Testing
@testable import PRMasterCore

@Suite("MainMenuItem")
struct MainMenuTests {

    /// A mistyped selector leaves the item dimmed with no error anywhere, so
    /// Command-W or Command-Q would silently do nothing.
    @Test("every item carries its standard selector and key", arguments: [
        (MainMenuItem.settings, "openSettingsFromMenu", ","),
        (.hide, "hide:", "h"),
        (.quit, "terminate:", "q"),
        (.close, "performClose:", "w"),
        (.minimize, "performMiniaturize:", "m"),
        (.zoom, "performZoom:", ""),
        (.bringAllToFront, "arrangeInFront:", ""),
    ])
    func itemsCarryTheirSelector(item: MainMenuItem, selector: String, key: String) {
        #expect(item.selectorName == selector)
        #expect(item.keyEquivalent == key)
    }

    @Test("items sit in the menus a Mac user looks in")
    func sections() {
        #expect(MainMenuItem.allCases.filter { $0.section == .app } == [.settings, .hide, .quit])
        #expect(MainMenuItem.allCases.filter { $0.section == .file } == [.close])
        #expect(MainMenuItem.allCases.filter { $0.section == .window } == [.minimize, .zoom, .bringAllToFront])
    }

    /// Two items on one shortcut leave one unreachable, and Edit's live in the same menu bar.
    @Test("no two items in the menu bar share a shortcut")
    func noShortcutCollisions() {
        let menu = MainMenuItem.allCases.map(\.keyEquivalent).filter { !$0.isEmpty }.map { "\($0)-false" }
        let edit = EditMenuItem.allCases.map { "\($0.keyEquivalent)-\($0.requiresShift)" }
        #expect(Set(menu + edit).count == menu.count + edit.count)
    }

    /// Command and a digit switch the popover's tabs.
    @Test("no menu shortcut takes a popover tab key")
    func digitsStayWithThePopover() {
        #expect(MainMenuItem.allCases.allSatisfy { Int($0.keyEquivalent) == nil })
    }

    @Test("every item has a distinct title")
    func titles() {
        #expect(MainMenuItem.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(Set(MainMenuItem.allCases.map(\.title)).count == MainMenuItem.allCases.count)
    }
}
