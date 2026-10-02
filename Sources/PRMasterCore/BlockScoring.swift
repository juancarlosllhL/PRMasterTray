import Foundation

public protocol BlockScoring: Sendable {
    func score(path: String, blocks: [DiffBlock]) async throws -> BlockScores
}

/// A block's own answer, and its changed lines' where they were asked and answered.
public struct BlockScore: Sendable, Equatable {
    public let block: LineHeat
    /// By position among the block's changed lines; nil takes the block's answer.
    public let lines: [LineHeat?]

    public init(block: LineHeat, lines: [LineHeat?]) {
        self.block = block
        self.lines = lines
    }

    public func heat(ofLine index: Int) -> LineHeat {
        lines.indices.contains(index) ? lines[index] ?? block : block
    }

    /// The hottest line drawn, so the sidebar never undersells a file.
    public var level: Importance {
        let own = lines.compactMap { $0 }
        let drawn = own.count == lines.count && !lines.isEmpty ? own : own + [block]
        return drawn.map(\.level).max() ?? block.level
    }
}

public struct BlockScores: Sendable, Equatable {
    /// One entry per block; nil where there is no score.
    public let blocks: [BlockScore?]
    /// Some block was too big to send at all.
    public let tooLarge: Bool

    public init(blocks: [BlockScore?], tooLarge: Bool) {
        self.blocks = blocks
        self.tooLarge = tooLarge
    }
}
