import Foundation
import Testing
@testable import PRMasterCore

@Suite("TitleOverflow")
struct TitleOverflowTests {

    @Test("only a title wider than its row is clipped", arguments: [
        (200.0, 100.0, true),
        (101.0, 100.0, true),
        (100.5, 100.0, false),
        (100.0, 100.0, false),
        (50.0, 100.0, false),
    ])
    func comparison(ideal: Double, shown: Double, expected: Bool) {
        #expect(TitleOverflow.isTruncated(ideal: ideal, shown: shown) == expected)
    }

    /// Both widths start at zero and arrive over two layout passes, so the first
    /// pass would otherwise arm a tooltip on every row at once.
    @Test("an unmeasured width never counts as clipped", arguments: [
        (0.0, 0.0), (0.0, 100.0), (200.0, 0.0),
    ])
    func unmeasured(ideal: Double, shown: Double) {
        #expect(!TitleOverflow.isTruncated(ideal: ideal, shown: shown))
    }
}
