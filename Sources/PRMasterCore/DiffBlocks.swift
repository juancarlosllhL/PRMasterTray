import Foundation

/// What a score is remembered by: the same change in the same file.
public struct BlockKey: Hashable, Sendable {
    let path: String
    let text: String
}

/// An unbroken run of added and removed lines inside one hunk.
public struct DiffBlock: Sendable, Equatable {
    public let hunk: Int
    /// Positions in the hunk's `lines`.
    public let lines: Range<Int>
    public let key: BlockKey
    /// Each changed line with its `+` or `-` marker.
    let changed: [String]
    let before: [String]
    let after: [String]
    let declaration: String
}

public enum DiffBlocks {

    static let contextLines = 3

    /// The changed lines with their markers, as the model reads them.
    public static func text(of block: DiffBlock) -> String { block.key.text }

    public static func blocks(in file: DiffFile) -> [DiffBlock] {
        guard case .hunks(let hunks) = file.content else { return [] }
        return hunks.enumerated().flatMap { index, hunk in blocks(in: hunk, at: index, path: file.path) }
    }

    private static func blocks(in hunk: Hunk, at index: Int, path: String) -> [DiffBlock] {
        let lines = hunk.lines
        var blocks: [DiffBlock] = []
        var start = 0
        while start < lines.count {
            guard lines[start].kind != .context else {
                start += 1
                continue
            }
            var end = start
            while end < lines.count, lines[end].kind != .context { end += 1 }
            let changed = lines[start..<end].map { ($0.kind == .added ? "+" : "-") + $0.text }
            blocks.append(DiffBlock(
                hunk: index,
                lines: start..<end,
                key: BlockKey(path: path, text: changed.joined(separator: "\n")),
                changed: changed,
                before: context(lines[max(0, start - contextLines)..<start].reversed()).reversed(),
                after: context(lines[end..<min(lines.count, end + contextLines)]),
                declaration: hunk.context
            ))
            start = end
        }
        return blocks
    }

    /// Context stops at the next change: that change is its own block.
    private static func context<S: Sequence>(_ lines: S) -> [String] where S.Element == DiffLine {
        Array(lines.prefix { $0.kind == .context }.map(\.text))
    }
}
