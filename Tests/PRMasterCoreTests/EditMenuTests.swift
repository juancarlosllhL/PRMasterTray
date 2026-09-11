import Foundation
import Testing
@testable import PRMasterCore

@Suite("EditMenuItem")
struct EditMenuTests {

    @Test("the item set is exhaustive")
    func itemSetIsExhaustive() {
        #expect(EditMenuItem.allCases.count == 6)
    }

    /// The whole bug: an accessory app has no main menu, so without these exact
    /// selectors nothing routes to the focused text field and Cmd+V does nothing.
    @Test("every item carries its standard selector and key", arguments: [
        (EditMenuItem.undo, "undo:", "z", false),
        (EditMenuItem.redo, "redo:", "z", true),
        (EditMenuItem.cut, "cut:", "x", false),
        (EditMenuItem.copy, "copy:", "c", false),
        (EditMenuItem.paste, "paste:", "v", false),
        (EditMenuItem.selectAll, "selectAll:", "a", false),
    ])
    func itemsCarryTheirSelector(
        item: EditMenuItem, selector: String, key: String, needsShift: Bool
    ) {
        #expect(item.selectorName == selector)
        #expect(item.keyEquivalent == key)
        #expect(item.requiresShift == needsShift)
    }

    @Test("paste is command-V")
    func pasteIsCommandV() {
        #expect(EditMenuItem.paste.keyEquivalent == "v")
        #expect(EditMenuItem.paste.selectorName == "paste:")
        #expect(!EditMenuItem.paste.requiresShift)
    }

    /// Two items sharing a shortcut would leave one unreachable. Undo and redo
    /// share "z" deliberately and are separated by shift.
    @Test("no two items collide on the same shortcut")
    func noShortcutCollisions() {
        let shortcuts = EditMenuItem.allCases.map { "\($0.keyEquivalent)-\($0.requiresShift)" }
        #expect(Set(shortcuts).count == EditMenuItem.allCases.count)
    }

    @Test("every item has a distinct title")
    func everyItemHasATitle() {
        #expect(EditMenuItem.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(Set(EditMenuItem.allCases.map(\.title)).count == EditMenuItem.allCases.count)
    }

    @Test("a separator follows redo")
    func separatorFollowsRedo() {
        #expect(EditMenuItem.redo.isFollowedBySeparator)
        #expect(EditMenuItem.allCases.filter(\.isFollowedBySeparator).count == 1)
    }
}
