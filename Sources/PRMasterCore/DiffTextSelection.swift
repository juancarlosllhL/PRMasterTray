import Foundation

public struct DiffTextPosition: Comparable, Hashable, Sendable {
    public let row: Int
    /// UTF-16 units into the row's text.
    public let offset: Int

    public init(row: Int, offset: Int) {
        self.row = row
        self.offset = offset
    }

    public static func < (lhs: DiffTextPosition, rhs: DiffTextPosition) -> Bool {
        (lhs.row, lhs.offset) < (rhs.row, rhs.offset)
    }
}

/// Text selected in one column of the diff table: the unified column, or one side of split.
public struct DiffTextSelection: Equatable, Sendable {
    public let column: Int
    public var anchor: DiffTextPosition
    public var focus: DiffTextPosition

    public init(column: Int, anchor: DiffTextPosition, focus: DiffTextPosition) {
        self.column = column
        self.anchor = anchor
        self.focus = focus
    }

    public var isEmpty: Bool { anchor == focus }

    /// Nil for rows outside the selection, rows with no text in this column, and empty spans.
    public func range(inRow row: Int, in rows: [DiffRow]) -> Range<Int>? {
        guard rows.indices.contains(row), let text = DiffRows.text(of: rows[row], column: column) else { return nil }
        let start = min(anchor, focus), end = max(anchor, focus)
        guard start.row <= row, row <= end.row else { return nil }
        let length = text.utf16.count
        let lower = row == start.row ? min(start.offset, length) : 0
        let upper = row == end.row ? min(end.offset, length) : length
        return lower < upper ? lower..<upper : nil
    }

    /// What Copy puts on the pasteboard: one line per selected row, headers left out.
    public func text(in rows: [DiffRow]) -> String {
        guard !isEmpty, !rows.isEmpty else { return "" }
        let first = max(min(anchor, focus).row, 0), last = min(max(anchor, focus).row, rows.count - 1)
        guard first <= last else { return "" }
        return (first...last).compactMap { row -> String? in
            guard let text = DiffRows.text(of: rows[row], column: column) else { return nil }
            guard let range = range(inRow: row, in: rows) else { return row == first || row == last ? nil : "" }
            return (text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
        }.joined(separator: "\n")
    }

    /// Letters, digits and underscores run together; anything else is a word of its own.
    public static func word(at offset: Int, in text: String) -> Range<Int> {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return 0..<0 }
        let offset = min(max(offset, 0), units.count - 1)
        guard isWordUnit(units[offset]) else { return offset..<offset + 1 }
        var lower = offset, upper = offset + 1
        while lower > 0, isWordUnit(units[lower - 1]) { lower -= 1 }
        while upper < units.count, isWordUnit(units[upper]) { upper += 1 }
        return lower..<upper
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }
}

extension DiffRows {
    /// The text a column of `row` shows, or nil for headers, notices and blank split sides.
    public static func text(of row: DiffRow, column: Int) -> String? {
        switch row {
        case .line(let line): return column == 0 ? line.text : nil
        case .pair(let left, let right): return (column == 0 ? left : right)?.text
        case .fileHeader, .section, .hunkHeader, .omitted: return nil
        }
    }
}
