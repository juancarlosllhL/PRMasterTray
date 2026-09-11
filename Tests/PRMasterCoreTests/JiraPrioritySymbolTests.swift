import Foundation
import Testing
@testable import PRMasterCore

/// Shown as an arrow rather than a word, so the shape has to carry the meaning
/// on its own — in monochrome there is no colour left to help.
@Suite("Jira priority arrows")
struct JiraPrioritySymbolTests {

    @Test("each priority points a different way", arguments: [
        (JiraPriority.critical, "chevron.up.2"),
        (.high, "chevron.up"),
        (.medium, "equal"),
        (.low, "chevron.down"),
        (.lowest, "chevron.down.2"),
    ])
    func symbols(priority: JiraPriority, expected: String) {
        #expect(priority.symbolName == expected)
    }

    @Test("no priority means no arrow")
    func unsetHasNone() {
        #expect(JiraPriority.unset.symbolName == nil)
        #expect(!JiraPriority.unset.isWorthShowing)
    }

    /// Two priorities sharing an arrow would be indistinguishable in monochrome.
    @Test("no two priorities share an arrow")
    func symbolsAreDistinct() {
        let shown = JiraPriority.allCases.compactMap(\.symbolName)
        #expect(shown.count == JiraPriority.allCases.count - 1)
        #expect(Set(shown).count == shown.count)
    }

    /// Urgency reads as a traffic light: red to act on, yellow to plan, blue to
    /// leave alone. The arrow still separates the two within each colour.
    @Test("the colour groups urgency, the arrow separates within it", arguments: [
        (JiraPriority.critical, ReadinessTint.red),
        (.high, .red),
        (.medium, .yellow),
        (.low, .blue),
        (.lowest, .blue),
        (.unset, .gray),
    ])
    func tints(priority: JiraPriority, expected: ReadinessTint) {
        #expect(priority.tint == expected)
    }
}
