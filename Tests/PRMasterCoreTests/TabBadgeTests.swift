import Foundation
import Testing
@testable import PRMasterCore

@Suite("TabBadge.resolve")
struct TabBadgeTests {

    /// A zero while the first fetch is still running would read as "nothing
    /// here", which is a claim the app cannot make yet.
    @Test("loading shows no number rather than a zero")
    func loadingShowsNothing() {
        #expect(TabBadge.resolve(state: .loading, count: 0) == TabBadge.none)
        #expect(TabBadge.resolve(state: .loading, count: 7) == TabBadge.none)
    }

    @Test("a failed pane warns instead of counting")
    func failedWarns() {
        #expect(TabBadge.resolve(state: .failed, count: 0) == .warning)
    }

    /// Several of these failures are otherwise indistinguishable from a tab that
    /// is genuinely empty, which is why the tab itself has to carry the signal.
    @Test("a routed pane failure warns even with rows present", arguments: [
        PaneState.content, .stale, .empty, .emptyByFilter, .loading,
    ])
    func routedFailureWarns(state: PaneState) {
        #expect(TabBadge.resolve(state: state, count: 4, hasRoutedFailure: true) == .warning)
    }

    @Test("a populated pane counts its rows", arguments: [
        (PaneState.content, 1), (PaneState.content, 42), (PaneState.stale, 3),
    ])
    func populatedCounts(state: PaneState, count: Int) {
        #expect(TabBadge.resolve(state: state, count: count) == .count(count))
    }

    /// The plan's decision: a zero-count tab still shows, just without a badge.
    @Test("an empty pane carries no badge", arguments: [
        PaneState.empty, .emptyByFilter, .content, .stale,
    ])
    func emptyCarriesNoBadge(state: PaneState) {
        #expect(TabBadge.resolve(state: state, count: 0) == TabBadge.none)
    }

    @Test("every pane state resolves to something", arguments: PaneState.allCases)
    func totalOverPaneStates(state: PaneState) {
        _ = TabBadge.resolve(state: state, count: 0)
        _ = TabBadge.resolve(state: state, count: 9)
    }
}

@Suite("PopoverBanner routing")
struct BannerRoutingTests {

    @Test("the banner set is exhaustive")
    func bannerSetIsExhaustive() {
        #expect(PopoverBanner.allCases.count == 8)
    }

    /// The routing table. Three are global and actionable; the rest belong to the
    /// pane whose data they describe.
    @Test("each banner routes to exactly one slot", arguments: [
        (PopoverBanner.notificationsDenied, BannerSlot.global),
        (PopoverBanner.updateAvailable, BannerSlot.global),
        (PopoverBanner.installFailure, BannerSlot.global),
        (PopoverBanner.notificationFailure, BannerSlot.pane(.mine)),
        (PopoverBanner.branchUpdateFailure, BannerSlot.pane(.mine)),
        (PopoverBanner.shipmentFailure, BannerSlot.pane(.merged)),
        (PopoverBanner.deploymentFailure, BannerSlot.pane(.merged)),
        (PopoverBanner.teamLookupFailure, BannerSlot.pane(.teams)),
    ])
    func routesToOneSlot(banner: PopoverBanner, slot: BannerSlot) {
        #expect(banner.slot == slot)
    }

    /// The whole point of the restructure: seven possible rows at once became
    /// one global plus whatever the visible pane owns.
    @Test("at most one global banner shows at a time")
    func onlyOneGlobalShows() {
        let all = Set(PopoverBanner.allCases)
        #expect(PopoverBanner.topGlobal(from: all) == .installFailure)
        #expect(PopoverBanner.topGlobal(from: [.updateAvailable, .notificationsDenied]) == .updateAvailable)
        #expect(PopoverBanner.topGlobal(from: [.notificationsDenied]) == .notificationsDenied)
        #expect(PopoverBanner.topGlobal(from: []) == nil)
    }

    /// A pane-owned banner must never be picked as the global one.
    @Test("pane banners are never global", arguments: [
        PopoverBanner.notificationFailure, .branchUpdateFailure,
        .shipmentFailure, .deploymentFailure, .teamLookupFailure,
    ])
    func paneBannersAreNotGlobal(banner: PopoverBanner) {
        #expect(PopoverBanner.topGlobal(from: [banner]) == nil)
        #expect(banner.slot != .global)
    }

    @Test("banners for a pane are the ones routed there", arguments: [
        (PopoverTab.mine, 2), (PopoverTab.merged, 2), (PopoverTab.teams, 1), (PopoverTab.jira, 0),
    ])
    func bannersForPane(tab: PopoverTab, expected: Int) {
        let active = Set(PopoverBanner.allCases)
        #expect(PopoverBanner.forPane(tab, from: active).count == expected)
    }

    /// Only the update notice is good news; everything else is a complaint, and
    /// the two are drawn in different colours.
    @Test("only updateAvailable is informational")
    func onlyUpdateIsInformational() {
        for banner in PopoverBanner.allCases {
            #expect(banner.isWarning == (banner != .updateAvailable))
        }
    }
}
