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
}
