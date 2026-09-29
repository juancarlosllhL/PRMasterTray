import Foundation
import Testing
@testable import PRMasterCore

private func pieces(_ text: String, width: Int) -> [String] {
    let units = Array(text.utf16)
    return LineWrap.segments(text, width: width).map { String(decoding: units[$0], as: UTF16.self) }
}

@Suite("LineWrap")
struct LineWrapTests {

    @Test("a line that fits is one segment")
    func fits() {
        #expect(pieces("let a = 1", width: 20) == ["let a = 1"])
    }

    @Test("an empty line is still one row")
    func empty() {
        #expect(LineWrap.segments("", width: 10) == [0..<0])
    }

    @Test("a line breaks after the last space that fits")
    func breaksAtSpaces() {
        #expect(pieces("aaa bbb ccc", width: 5) == ["aaa ", "bbb ", "ccc"])
    }

    @Test("a space that lands on the edge stays at the end of its segment")
    func spaceOnTheEdge() {
        #expect(pieces("aaa bbb ccc", width: 7) == ["aaa bbb ", "ccc"])
    }

    @Test("a word longer than the width is split rather than overflowing")
    func longWord() {
        #expect(pieces("abcdefghij", width: 4) == ["abcd", "efgh", "ij"])
    }

    @Test("a tab counts to the next four-column stop")
    func tabs() {
        #expect(pieces("\tab", width: 6) == ["\tab"])
        #expect(pieces("\tabc", width: 6) == ["\t", "abc"])
    }

    @Test("an emoji is never cut in half")
    func surrogatePairs() {
        let segments = pieces("🙂🙂🙂", width: 3)
        #expect(segments.joined() == "🙂🙂🙂")
        #expect(segments.allSatisfy { !$0.contains("\u{FFFD}") })
    }

    @Test("segments cover the line exactly once, in order")
    func coversEverything() {
        let text = "func render(_ rows: [DiffRow], into table: NSTableView, palette: ResolvedPalette) -> Int"
        let segments = LineWrap.segments(text, width: 17)
        #expect(segments.first?.lowerBound == 0)
        #expect(segments.last?.upperBound == text.utf16.count)
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(segments.count > 1)
    }

    @Test("a width below one column still makes progress")
    func tinyWidth() {
        #expect(pieces("ab", width: 0) == ["a", "b"])
    }

    @Test("a character wider than a column takes the room it really needs")
    func wideCharacters() {
        let wide: (Unicode.Scalar) -> Double = { $0.isASCII ? 1 : 1.6 }
        let units = Array("ab漢漢漢".utf16)
        let segments = LineWrap.segments("ab漢漢漢", width: 5, columns: wide)
        let texts = segments.map { String(decoding: units[$0], as: UTF16.self) }
        #expect(texts == ["ab漢", "漢漢"])
    }

    @Test("narrow characters let more fit on a line")
    func narrowCharacters() {
        let narrow: (Unicode.Scalar) -> Double = { $0.isASCII ? 1 : 0.5 }
        #expect(LineWrap.segments("ᚋᚋᚋᚋᚋᚋ", width: 3, columns: narrow).count == 1)
    }

    @Test("gqlgen's Ogham separators wrap without spilling past the width")
    func gqlgenIdentifier() {
        let text = "unmarshalNAnalyticsFilterInput2ᚖgithubᚗcomᚋLansweeperᚋLECLuzmoPluginᚋinternal"
        let measured: (Unicode.Scalar) -> Double = { $0.isASCII ? 1 : 1.03 }
        let units = Array(text.utf16)
        for segment in LineWrap.segments(text, width: 20, columns: measured) {
            let width = String(decoding: units[segment], as: UTF16.self).unicodeScalars.reduce(0) { $0 + measured($1) }
            #expect(width <= 20)
        }
    }

    @Test("a click lands before the character whose left half it hits, after it on the right half")
    func offsetRoundsToNearestBoundary() {
        let text = "let a"
        #expect(LineWrap.offset(atColumn: 0.4, in: text, segment: 0..<5) == 0)
        #expect(LineWrap.offset(atColumn: 0.6, in: text, segment: 0..<5) == 1)
        #expect(LineWrap.offset(atColumn: 2.9, in: text, segment: 0..<5) == 3)
    }

    @Test("a click left of the code or past the end of a segment clamps to its ends")
    func offsetClamps() {
        #expect(LineWrap.offset(atColumn: -3, in: "let a", segment: 0..<5) == 0)
        #expect(LineWrap.offset(atColumn: 40, in: "let a", segment: 0..<5) == 5)
    }

    @Test("a continuation segment counts columns from its own start, as it is drawn")
    func offsetInLaterSegment() {
        let text = "alpha beta gamma"
        let segments = LineWrap.segments(text, width: 6)
        #expect(segments.count > 1)
        let second = segments[1]
        #expect(LineWrap.offset(atColumn: 0, in: text, segment: second) == second.lowerBound)
        #expect(LineWrap.offset(atColumn: 2.2, in: text, segment: second) == second.lowerBound + 2)
    }

    @Test("a tab spans to the next stop, and wide characters take their measured width")
    func offsetTabsAndWideCharacters() {
        #expect(LineWrap.offset(atColumn: 3.9, in: "\tx", segment: 0..<2) == 1)
        #expect(LineWrap.offset(atColumn: 1.9, in: "\tx", segment: 0..<2) == 0)
        let wide: (Unicode.Scalar) -> Double = { $0.isASCII ? 1 : 2 }
        #expect(LineWrap.offset(atColumn: 1.5, in: "界a", segment: 0..<2, columns: wide) == 1)
        #expect(LineWrap.offset(atColumn: 0.9, in: "界a", segment: 0..<2, columns: wide) == 0)
    }

    @Test("an emoji is one character but two UTF-16 units")
    func offsetCountsUTF16() {
        #expect(LineWrap.offset(atColumn: 1.4, in: "🙂a", segment: 0..<3) == 2)
    }
}
