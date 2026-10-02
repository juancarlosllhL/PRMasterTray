@testable import PRMasterCore

extension BlockScores {
    /// One confident score per block, every line taking it.
    init(levels: [Importance?], tooLarge: Bool) {
        self.init(blocks: levels.map { $0.map(BlockScore.init(level:)) }, tooLarge: tooLarge)
    }
}

extension BlockScore {
    init(level: Importance) {
        self.init(block: LineHeat(score: Double(level.rawValue), confidence: 0.9), lines: [])
    }
}
