import Testing
@testable import PRMasterCore

/// Uncertainty is drawn as hatching, so a level no longer has to absorb it:
/// a score shows as the level it is closest to.
@Suite("Importance")
struct ImportanceTests {

    @Test(
        "a score shows as its nearest level, halfway rounding up",
        arguments: [
            (0.0, Importance.glue), (0.49, .glue), (0.5, .routine), (1.43, .routine),
            (1.5, .logic), (2.49, .logic), (2.5, .sensitive), (3.0, .sensitive),
        ]
    )
    func nearestLevel(score: Double, expected: Importance) {
        #expect(Importance(score: score) == expected)
    }

    @Test("scores outside the scale clamp to its ends, and a broken one asks for attention")
    func clamps() {
        #expect(Importance(score: -1) == .glue)
        #expect(Importance(score: 7.5) == .sensitive)
        #expect(Importance(score: .nan) == .sensitive)
    }

    @Test("levels order from glue to sensitive, so a file's heat is its maximum")
    func ordered() {
        #expect(Importance.allCases == [.glue, .routine, .logic, .sensitive])
        #expect([Importance.routine, .sensitive, .glue].max() == .sensitive)
    }
}

/// A line's own answer is what gets drawn; the block's answer covers what the
/// line question could not, so no changed line is ever left blank.
@Suite("Line heat")
struct LineHeatTests {

    @Test("a score keeps its exact value inside the scale")
    func clampsScore() {
        #expect(LineHeat(score: 2.37, confidence: 0.6).score == 2.37)
        #expect(LineHeat(score: 4, confidence: nil).score == 3)
        #expect(LineHeat(score: -0.5, confidence: nil).score == 0)
        #expect(LineHeat(score: .nan, confidence: nil).score == 3)
    }

    @Test("below 0.35 confidence a line is uncertain; without a confidence it is not")
    func uncertainty() {
        #expect(LineHeat(score: 2, confidence: 0.34).isUncertain)
        #expect(!LineHeat(score: 2, confidence: 0.35).isUncertain)
        #expect(!LineHeat(score: 2, confidence: nil).isUncertain)
    }

    @Test("a line without its own answer takes the block's")
    func inheritsBlock() {
        let block = LineHeat(score: 2.8, confidence: 0.7)
        let own = LineHeat(score: 0.4, confidence: 0.9)
        let score = BlockScore(block: block, lines: [own, nil])
        #expect(score.heat(ofLine: 0) == own)
        #expect(score.heat(ofLine: 1) == block)
        #expect(score.heat(ofLine: 5) == block)
        #expect(score.level == .sensitive)
    }

    @Test("a block's level is its hottest line, so the sidebar never undersells a file")
    func blockLevelIsHottestLine() {
        let score = BlockScore(block: LineHeat(score: 1, confidence: 0.8), lines: [LineHeat(score: 2.9, confidence: 0.8)])
        #expect(score.level == .sensitive)
    }
}
