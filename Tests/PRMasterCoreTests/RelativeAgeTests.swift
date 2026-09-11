import Foundation
import Testing
@testable import PRMasterCore

@Suite("RelativeAge")
struct RelativeAgeTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func label(secondsAgo: Double) -> String {
        RelativeAge.label(since: Self.now.addingTimeInterval(-secondsAgo), now: Self.now)
    }

    @Test("reads as a sentence at every boundary", arguments: [
        (0.0, "just now"),
        (59.0, "just now"),
        (60.0, "1 minute ago"),
        (119.0, "1 minute ago"),
        (120.0, "2 minutes ago"),
        (3_540.0, "59 minutes ago"),
        (3_600.0, "1 hour ago"),
        (7_200.0, "2 hours ago"),
        (86_399.0, "23 hours ago"),
        (86_400.0, "1 day ago"),
        (172_800.0, "2 days ago"),
        (2_505_600.0, "29 days ago"),
        (2_592_000.0, "1 month ago"),
        (5_184_000.0, "2 months ago"),
        (31_449_600.0, "12 months ago"),
        (31_536_000.0, "1 year ago"),
        (63_072_000.0, "2 years ago"),
    ])
    func boundaries(secondsAgo: Double, expected: String) {
        #expect(label(secondsAgo: secondsAgo) == expected)
    }

    /// A machine whose clock lags the server would otherwise count backwards.
    @Test("a date in the future is not negative")
    func futureClamps() {
        #expect(RelativeAge.label(
            since: Self.now.addingTimeInterval(9_000), now: Self.now
        ) == "just now")
    }

    @Test("one of anything is singular, everything else is plural")
    func singularAndPlural() {
        #expect(label(secondsAgo: 3_600) == "1 hour ago")
        #expect(label(secondsAgo: 7_200).hasSuffix("hours ago"))
        #expect(label(secondsAgo: 86_400) == "1 day ago")
        #expect(label(secondsAgo: 2_592_000) == "1 month ago")
    }
}
