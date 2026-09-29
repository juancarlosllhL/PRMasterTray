import Testing
@testable import PRMasterCore

@Suite("Readiness presentation")
struct PresentationTests {

    /// Mirrors the table in the design doc, so a drift between the two fails
    /// here rather than being noticed in the menu bar weeks later.
    @Test("glyph and tint match the design table", arguments: [
        (Readiness.ready, StatusGlyph.ready, ReadinessTint.green),
        (Readiness.behind, StatusGlyph.behind, ReadinessTint.yellow),
        (Readiness.quillComments, StatusGlyph.quill, ReadinessTint.orange),
        (Readiness.unresolvedComments, StatusGlyph.comments, ReadinessTint.orange),
        (Readiness.blocked, StatusGlyph.waiting, ReadinessTint.blue),
        (Readiness.checksPending, StatusGlyph.pending, ReadinessTint.yellow),
        (Readiness.checksFailing, StatusGlyph.failing, ReadinessTint.red),
        (Readiness.conflicted, StatusGlyph.conflicted, ReadinessTint.orange),
        (Readiness.draft, StatusGlyph.draft, ReadinessTint.gray),
    ])
    func glyphTable(state: Readiness, glyph: StatusGlyph, tint: ReadinessTint) {
        #expect(state.glyph == glyph)
        #expect(state.tint == tint)
    }

    @Test("every state has a distinct glyph")
    func glyphsAreDistinct() {
        let symbols = Readiness.allCases.map(\.glyph)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("every state has a non-empty label for accessibility")
    func labelsExist() {
        for state in Readiness.allCases {
            #expect(!state.label.isEmpty)
        }
    }

    /// One past "Waiting for review", which was measured not to clip at 380pt.
    @Test("labels stay short enough for the row", arguments: Readiness.allCases)
    func labelsFit(state: Readiness) {
        #expect(state.label.count <= 19)
    }

    @Test("only drafts are dimmed")
    func onlyDraftsDimmed() {
        for state in Readiness.allCases {
            #expect(state.isDimmed == (state == .draft))
        }
    }
}
