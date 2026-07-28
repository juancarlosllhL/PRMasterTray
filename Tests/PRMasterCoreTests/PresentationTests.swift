import Testing
@testable import PRMasterCore

@Suite("Readiness presentation")
struct PresentationTests {

    /// Mirrors the table in the design doc, so a drift between the two fails
    /// here rather than being noticed in the menu bar weeks later.
    @Test("glyph and tint match the design table", arguments: [
        (Readiness.ready, "checkmark.circle.fill", ReadinessTint.green),
        (Readiness.behind, "arrow.down.circle", ReadinessTint.yellow),
        (Readiness.blocked, "eye.circle", ReadinessTint.blue),
        (Readiness.checksPending, "clock", ReadinessTint.yellow),
        (Readiness.checksFailing, "xmark.circle.fill", ReadinessTint.red),
        (Readiness.conflicted, "exclamationmark.triangle.fill", ReadinessTint.orange),
        (Readiness.draft, "pencil.circle", ReadinessTint.gray),
    ])
    func glyphTable(state: Readiness, symbol: String, tint: ReadinessTint) {
        #expect(state.symbolName == symbol)
        #expect(state.tint == tint)
    }

    @Test("every state has a distinct glyph")
    func glyphsAreDistinct() {
        let symbols = Readiness.allCases.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("every state has a non-empty label for accessibility")
    func labelsExist() {
        for state in Readiness.allCases {
            #expect(!state.label.isEmpty)
        }
    }

    @Test("only drafts are dimmed")
    func onlyDraftsDimmed() {
        for state in Readiness.allCases {
            #expect(state.isDimmed == (state == .draft))
        }
    }
}
