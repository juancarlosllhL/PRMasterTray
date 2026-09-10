import Foundation

public enum BannerSlot: Sendable, Equatable {
    case global
    case pane(PopoverTab)
}

public enum PopoverBanner: String, Sendable, Equatable, CaseIterable {
    case notificationsDenied
    case notificationFailure
    case shipmentFailure
    case deploymentFailure
    case branchUpdateFailure
    case teamLookupFailure
    case updateAvailable
    case installFailure

    /// Global means actionable whichever pane is on screen. The rest belong to
    /// the pane whose data they describe, because several are otherwise
    /// indistinguishable from that pane being genuinely empty.
    public var slot: BannerSlot {
        switch self {
        case .notificationsDenied, .updateAvailable, .installFailure:
            return .global
        case .notificationFailure, .branchUpdateFailure,
             .shipmentFailure, .deploymentFailure, .teamLookupFailure:
            return .pane(.pullRequests)
        }
    }

    public var isWarning: Bool {
        self != .updateAvailable
    }

    private static let globalPriority: [PopoverBanner] = [
        .installFailure, .updateAvailable, .notificationsDenied,
    ]

    public static func topGlobal(from active: Set<PopoverBanner>) -> PopoverBanner? {
        globalPriority.first(where: active.contains)
    }

    public static func forPane(
        _ tab: PopoverTab,
        from active: Set<PopoverBanner>
    ) -> [PopoverBanner] {
        allCases.filter { active.contains($0) && $0.slot == .pane(tab) }
    }
}
