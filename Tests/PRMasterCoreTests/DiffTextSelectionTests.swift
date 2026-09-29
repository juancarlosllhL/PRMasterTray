import Foundation
import Testing
@testable import PRMasterCore

private func line(_ text: String, _ kind: DiffLine.Kind = .context) -> DiffLine {
    DiffLine(kind: kind, oldNumber: 1, newNumber: 1, text: text)
}

private let unified: [DiffRow] = [
    .fileHeader(path: "a.swift"),
    .hunkHeader("@@ -1,3 +1,3 @@"),
    .line(line("let alpha = 1")),
    .line(line("let beta = 2", .added)),
    .fileHeader(path: "b.swift"),
    .line(line("let gamma = 3")),
]

private func selection(_ column: Int, _ anchor: (Int, Int), _ focus: (Int, Int)) -> DiffTextSelection {
    DiffTextSelection(
        column: column,
        anchor: DiffTextPosition(row: anchor.0, offset: anchor.1),
        focus: DiffTextPosition(row: focus.0, offset: focus.1)
    )
}

@Suite("Diff text selection")
struct DiffTextSelectionTests {

    @Test("a selection inside one line covers just that span")
    func withinLine() {
        let chosen = selection(0, (2, 4), (2, 9))
        #expect(chosen.range(inRow: 2, in: unified) == 4..<9)
        #expect(chosen.text(in: unified) == "alpha")
        #expect(chosen.range(inRow: 3, in: unified) == nil)
    }

    @Test("dragging upwards selects the same text as dragging down")
    func reversed() {
        #expect(selection(0, (3, 3), (2, 4)).text(in: unified) == selection(0, (2, 4), (3, 3)).text(in: unified))
        #expect(selection(0, (3, 3), (2, 4)).text(in: unified) == "alpha = 1\nlet")
    }

    @Test("rows in between are selected whole, and headers are left out of the copy")
    func acrossRowsAndHeaders() {
        let chosen = selection(0, (2, 10), (5, 3))
        #expect(chosen.range(inRow: 3, in: unified) == 0..<12)
        #expect(chosen.range(inRow: 4, in: unified) == nil)
        #expect(chosen.text(in: unified) == "= 1\nlet beta = 2\nlet")
    }

    @Test("in split view only the side the selection started on is selected")
    func splitColumns() {
        let rows: [DiffRow] = [
            .pair(left: line("old one", .removed), right: line("new one", .added)),
            .pair(left: nil, right: line("new two", .added)),
            .pair(left: line("old three", .removed), right: nil),
        ]
        let right = selection(1, (0, 4), (2, 0))
        #expect(right.text(in: rows) == "one\nnew two")
        #expect(right.range(inRow: 2, in: rows) == nil)
        let left = selection(0, (0, 0), (2, 3))
        #expect(left.text(in: rows) == "old one\nold")
        #expect(left.range(inRow: 1, in: rows) == nil)
    }

    @Test("an empty selection selects and copies nothing")
    func empty() {
        let chosen = selection(0, (2, 4), (2, 4))
        #expect(chosen.isEmpty)
        #expect(chosen.range(inRow: 2, in: unified) == nil)
        #expect(chosen.text(in: unified) == "")
    }

    @Test("positions past a row's end, or on rows that are gone, are clamped rather than trapping")
    func outOfBounds() {
        let chosen = selection(0, (2, 4), (40, 99))
        #expect(chosen.range(inRow: 5, in: unified) == 0..<13)
        #expect(chosen.text(in: unified).hasPrefix("alpha = 1\n"))
        #expect(selection(0, (2, 40), (2, 50)).range(inRow: 2, in: unified) == nil)
    }

    @Test(
        "a double-click selects the word under it, or the single character when it is not part of one",
        arguments: [
            (5, 4..<9), (4, 4..<9), (9, 9..<10), (10, 10..<11), (13, 12..<13), (0, 0..<3),
        ]
    )
    func word(offset: Int, expected: Range<Int>) {
        #expect(DiffTextSelection.word(at: offset, in: "let alpha = 1") == expected)
    }

    @Test("a double-click on an empty line selects nothing")
    func wordOnEmptyLine() {
        #expect(DiffTextSelection.word(at: 0, in: "") == 0..<0)
    }
}
