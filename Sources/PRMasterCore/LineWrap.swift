/// Soft wrapping on character columns. ASCII is exactly one column in the
/// monospaced font; anything else is drawn by a fallback font at its own width,
/// which the caller measures and passes in as `columns`.
public enum LineWrap {

    /// UTF-16 ranges covering `text` in order. Breaks after the last space or
    /// tab that fits, and splits a word only when it is wider than `width`.
    public static func segments(
        _ text: String, width: Int, tabWidth: Int = 4,
        columns: (Unicode.Scalar) -> Double = { _ in 1 }
    ) -> [Range<Int>] {
        var scalars: [(offset: Int, scalar: Unicode.Scalar)] = []
        var offset = 0
        for scalar in text.unicodeScalars {
            scalars.append((offset, scalar))
            offset += scalar.utf16.count
        }
        let total = offset
        let width = Double(max(width, 1))
        let tab = Double(tabWidth)

        func advance(_ scalar: Unicode.Scalar, at column: Double) -> Double {
            scalar == "\t" ? tab - column.truncatingRemainder(dividingBy: tab) : columns(scalar)
        }

        func span(_ range: Range<Int>) -> Double {
            range.reduce(0.0) { $0 + advance(scalars[$1].scalar, at: $0) }
        }

        var segments: [Range<Int>] = []
        var start = 0, column = 0.0
        var lastBreak: Int?
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index].scalar
            let isBreak = scalar == " " || scalar == "\t"
            if column + advance(scalar, at: column) > width, index > start {
                if isBreak {
                    segments.append(scalars[start].offset..<utf16End(index, scalars, total))
                    start = index + 1
                    column = 0
                    lastBreak = nil
                    index += 1
                    continue
                }
                let end = lastBreak ?? index
                segments.append(scalars[start].offset..<scalars[end].offset)
                start = end
                column = span(start..<index)
                lastBreak = nil
            }
            column += advance(scalar, at: column)
            if isBreak { lastBreak = index + 1 }
            index += 1
        }
        if start < scalars.count {
            segments.append(scalars[start].offset..<total)
        } else if segments.isEmpty {
            segments.append(0..<0)
        }
        return segments
    }

    private static func utf16End(_ index: Int, _ scalars: [(offset: Int, scalar: Unicode.Scalar)], _ total: Int) -> Int {
        index + 1 < scalars.count ? scalars[index + 1].offset : total
    }
}
