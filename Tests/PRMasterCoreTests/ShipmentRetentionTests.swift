import Foundation
import Testing
@testable import PRMasterCore

@Suite("Shipment retention")
struct ShipmentRetentionTests {

    private let now = Date(timeIntervalSince1970: 1_786_692_165)

    @Test("a pull request merged just under the window is kept")
    func justInsideIsKept() {
        let mergedAt = now.addingTimeInterval(-(23 * 3600 + 59 * 60))
        #expect(ShipmentRetention.isRecent(mergedAt: mergedAt, now: now))
    }

    @Test("a pull request merged just over the window is dropped")
    func justOutsideIsDropped() {
        let mergedAt = now.addingTimeInterval(-(24 * 3600 + 60))
        #expect(ShipmentRetention.isRecent(mergedAt: mergedAt, now: now) == false)
    }

    /// A clock that disagrees with GitHub's must not hide a merge that has just
    /// landed. Anything dated in the future is still recent.
    @Test("a merge timestamped in the future is kept")
    func futureIsKept() {
        #expect(ShipmentRetention.isRecent(mergedAt: now.addingTimeInterval(600), now: now))
    }

    /// The one rule that matters here: the window the search asks for and the
    /// window the list displays are the same number. If they ever drift, rows
    /// either vanish while still being fetched or are fetched and never shown.
    @Test("the search qualifier is derived from the same cutoff as the display")
    func qualifierMatchesTheWindow() {
        let qualifier = ShipmentRetention.mergedQualifier(now: now)
        let cutoff = now.addingTimeInterval(-ShipmentRetention.window)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(qualifier == "merged:>\(formatter.string(from: cutoff))")

        // The boundary the qualifier names is exactly the boundary isRecent uses.
        #expect(ShipmentRetention.isRecent(mergedAt: cutoff.addingTimeInterval(1), now: now))
        #expect(ShipmentRetention.isRecent(mergedAt: cutoff.addingTimeInterval(-1), now: now) == false)
    }

    @Test("filtering keeps only the recent merges, in the order given")
    func filtersInOrder() {
        let fresh = stub(id: "fresh", mergedAt: now.addingTimeInterval(-3600))
        let old = stub(id: "old", mergedAt: now.addingTimeInterval(-48 * 3600))

        let kept = ShipmentRetention.recent([fresh, old], now: now)
        #expect(kept.map(\.id) == ["fresh"])
    }

    private func stub(id: String, mergedAt: Date) -> MergedPullRequest {
        MergedPullRequest(
            id: id,
            number: 1,
            title: "t",
            url: URL(string: "https://github.com/acme/widget-service/pull/1")!,
            repo: "acme/widget-service",
            repositoryID: "R_1",
            isPrivate: false,
            mergedAt: mergedAt,
            mergeCommitOid: nil,
            rollupState: nil,
            contexts: []
        )
    }
}
