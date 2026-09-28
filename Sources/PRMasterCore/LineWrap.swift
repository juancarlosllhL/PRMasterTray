/// Soft wrapping on character columns, which a monospaced font makes exact:
/// the table sizes each row from the segment count and draws the same segments.
public enum LineWrap {

    /// UTF-16 ranges covering `text` in order. Breaks after the last space or
    /// tab that fits, and splits a word only when it is wider than `width`.
    public static func segments(_ text: String, width: Int, tabWidth: Int = 4) -> [Range<Int>] {
        let units = Array(text.utf16)
        let width = max(width, 1)
        var segments: [Range<Int>] = []
        var start = 0, column = 0
        var lastBreak: Int?

        func advance(_ unit: UInt16, at column: Int) -> Int {
            unit == tab ? tabWidth - column % tabWidth : 1
        }

        func columns(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 + advance(units[$1], at: $0) }
        }

        var index = 0
        while index < units.count {
            let unit = units[index]
            let step = advance(unit, at: column)
            if column + step > width, index > start {
                if unit == space || unit == tab {
                    segments.append(start..<index + 1)
                    start = index + 1
                    column = 0
                    lastBreak = nil
                    index += 1
                    continue
                }
                var end = lastBreak ?? index
                if end == index, isLowSurrogate(unit), index - 1 > start { end = index - 1 }
                segments.append(start..<end)
                start = end
                column = columns(start..<index)
                lastBreak = nil
            }
            column += advance(unit, at: column)
            if unit == space || unit == tab { lastBreak = index + 1 }
            index += 1
        }
        if start < units.count || segments.isEmpty { segments.append(start..<units.count) }
        return segments
    }
}

private let space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t"))

private func isLowSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
