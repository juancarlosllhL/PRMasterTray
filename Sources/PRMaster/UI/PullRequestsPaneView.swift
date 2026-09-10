import SwiftUI
import PRMasterCore

/// The three sections that were the whole popover, with the layout and the
/// per-section scroll caps they have always had.
struct PullRequestsPaneView: View {
    @Bindable var store: PRStore
    let reviews: ReviewStore
    let canMerge: Bool
    let canClose: Bool
    let canApprove: Bool
    let onOpen: (PullRequest) -> Void
    let onMerge: (PullRequest) -> Void
    let onClose: (PullRequest) -> Void
    let onOpenShipment: (Shipment) -> Void
    let onOpenReviewRequest: (ReviewRequest) -> Void
    let onApproveReviewRequest: (ReviewRequest) -> Void
    let onOpenSettings: () -> Void

    private static let rowsBeforeScrolling = 8
    private static let mergedRowsBeforeScrolling = 5
    private static let reviewRowsBeforeScrolling = 5

    private var reviewRequests: [ReviewRequest] { reviews.visible(under: store.filter) }

    var body: some View {
        VStack(spacing: 0) {
            content
            // Outside `content` on purpose: a day with nothing open but
            // something merged is exactly when this section is worth having,
            // and putting it inside would hide it behind the empty state.
            if !store.shipments.isEmpty {
                Divider()
                mergedSection
            }
            if !reviewRequests.isEmpty {
                Divider()
                teamsSection
            }
            if let failure = store.lastNotificationFailure {
                Divider()
                BannerRowView(
                    icon: "bell.badge.slash",
                    text: "Couldn't show a notification — \(failure). Retrying."
                )
            }
            if let failure = store.lastShipmentFailure {
                Divider()
                BannerRowView(icon: "shippingbox", text: "Couldn't check what shipped — \(failure)")
            }
            if let failure = store.lastDeploymentFailure {
                Divider()
                BannerRowView(
                    icon: "square.stack.3d.up",
                    text: "Couldn't check stg and prod — \(failure)"
                )
            }
            if let failure = store.lastUpdateFailure {
                Divider()
                BannerRowView(
                    icon: "arrow.triangle.pull",
                    text: "Couldn't update a branch — \(failure)"
                )
            }
            if let failure = reviews.lastError {
                Divider()
                BannerRowView(
                    icon: "person.2",
                    text: "Couldn't check your teams — \(failure.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Open pull requests

    private var state: PaneState {
        PaneState.resolve(
            rowCount: store.prs.count,
            hiddenCount: store.hiddenCount,
            lastError: store.lastError,
            lastSuccessfulFetch: store.lastSuccessfulFetch
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            PaneMessageView(icon: "arrow.triangle.pull", title: "Loading…")
        case .failed:
            PaneMessageView(
                icon: "exclamationmark.triangle",
                title: "Couldn't reach GitHub",
                detail: store.lastError?.localizedDescription
            )
        case .emptyByFilter:
            PaneMessageView(
                icon: "line.3.horizontal.decrease.circle",
                title: "Nothing to show",
                detail: PRListView.hiddenSummary(store.hiddenCount),
                actionTitle: "Settings…",
                action: onOpenSettings
            )
        case .empty:
            PaneMessageView(
                icon: "checkmark.circle",
                title: "No open pull requests",
                detail: "Nothing of yours is waiting to merge."
            )
        case .content, .stale:
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if let banner = staleBanner {
                BannerRowView(icon: "exclamationmark.triangle.fill", text: banner)
                Divider()
            }
            // A ScrollView is greedy and would leave dead space below a short
            // list, so only reach for one when the list is genuinely long.
            if store.prs.count > Self.rowsBeforeScrolling {
                ScrollView { openRows }
                    .frame(height: 460)
            } else {
                openRows
            }
        }
    }

    private var openRows: some View {
        let now = Date()
        let threshold = store.staleThreshold

        return LazyVStack(spacing: 2) {
            ForEach(store.prs) { pr in
                PRRowView(
                    pr: pr,
                    canMerge: canMerge,
                    isUpdating: store.updatingIDs.contains(pr.id),
                    isStale: threshold.isStale(createdAt: pr.createdAt, now: now),
                    staleAge: StaleAge.label(createdAt: pr.createdAt, now: now),
                    canClose: canClose,
                    onOpen: { onOpen(pr) },
                    onMerge: { onMerge(pr) },
                    onClose: { onClose(pr) }
                )
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }

    private var staleBanner: String? {
        guard let error = store.lastError else { return nil }
        guard let last = store.lastSuccessfulFetch else { return error.localizedDescription }
        return "Couldn't refresh · updated \(PRListView.ago(last)) · \(error.localizedDescription)"
    }

    // MARK: - Recently merged

    private var mergedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeaderView(title: "Recently merged")
            // Capped like the open list above it. A busy day can merge dozens,
            // and an uncapped section would push the popover off the screen.
            if store.shipments.count > Self.mergedRowsBeforeScrolling {
                ScrollView { mergedRows }
                    .frame(height: 220)
            } else {
                mergedRows
            }
        }
    }

    private var mergedRows: some View {
        LazyVStack(spacing: 2) {
            ForEach(store.shipments) { shipment in
                ShipmentRowView(
                    shipment: shipment,
                    isLoadingEnvironments: store.isLoadingDeployments
                ) { onOpenShipment(shipment) }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    // MARK: - Waiting on your teams

    private var teamsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeaderView(
                title: "Waiting on your teams",
                trailing: reviews.isTruncated(under: store.filter) ? "most recent" : nil,
                trailingHelp: "Your teams have more waiting than this shows. Narrow the window or switch teams off in Settings."
            )
            // Capped like the two sections above it. Even inside the age limit a
            // busy team can carry dozens, and an uncapped section would push the
            // popover off the screen.
            if reviewRequests.count > Self.reviewRowsBeforeScrolling {
                ScrollView { teamRows }
                    .frame(height: 260)
            } else {
                teamRows
            }
        }
    }

    private var teamRows: some View {
        let now = Date()

        return LazyVStack(spacing: 2) {
            ForEach(reviewRequests) { request in
                ReviewRequestRowView(
                    request: request,
                    canApprove: canApprove,
                    isApproving: reviews.approvingIDs.contains(request.id),
                    age: StaleAge.recentLabel(createdAt: request.createdAt, now: now),
                    onOpen: { onOpenReviewRequest(request) },
                    onApprove: { onApproveReviewRequest(request) }
                )
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}
