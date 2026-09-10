import SwiftUI
import PRMasterCore

struct PRListView: View {
    @Bindable var store: PRStore
    /// The teams half of the popover. Its own store, so a failure fetching other
    /// people's pull requests cannot raise the stale banner over the user's own.
    let reviews: ReviewStore
    let onOpen: (PullRequest) -> Void
    let onMerge: (PullRequest) -> Void
    let onClose: (PullRequest) -> Void
    /// Opens whatever the row is about: the pipeline while it runs, the release
    /// once there is one.
    let onOpenShipment: (Shipment) -> Void
    let onOpenReviewRequest: (ReviewRequest) -> Void
    let onApprove: (ReviewRequest) -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    /// False while a debug override is active, so the app never offers an
    /// action it is going to refuse.
    let canMerge: Bool
    /// Also false under a debug override, and with no demo exception: closing
    /// takes no expectedHeadOid, so this flag is the only thing between a
    /// fixture row and the real pull request it names.
    let canClose: Bool
    /// Also false under a debug override, where the store has no updater at
    /// all — offering a switch for a feature that cannot run would be a lie.
    let canAutoUpdate: Bool
    /// Also false under a debug override, and with no demo exception for the same
    /// reason closing has none — see `ApproveCoordinator`.
    let canApprove: Bool
    @Bindable var notifications: NotificationStatus
    /// App-update state. Nothing to bind to — every property is read-only — so a
    /// plain `let` is enough; `@Observable` tracks the reads either way.
    let updates: AppUpdateStore
    /// Read live rather than snapshotted. The popover's rootView is built once,
    /// so a plain `Bool` would freeze the switch at whatever it was at launch;
    /// reading the property inside `palette` lets `@Observable` track it and
    /// re-render when it flips. Same reason `updates` is a plain `let`.
    let appearance: AppearanceStore
    /// Read live for the same reason as `appearance`, and with more need of it:
    /// this one's truth lives in System Settings, where the user can change it
    /// behind the app's back.
    let launchAtLogin: LaunchAtLoginStore

    /// Not `private`: a private stored property would make the synthesised
    /// memberwise initialiser private too, and `AppDelegate` builds this view.
    var paletteInputs = PaletteInputs()

    let selection: TabSelectionStore

    var visibleTabs: [PopoverTab] { PopoverTab.allCases }

    private var activeTab: PopoverTab {
        selection.resolved(visible: visibleTabs)
    }

    private var tabBinding: Binding<PopoverTab> {
        Binding(get: { activeTab }, set: { selection.select($0) })
    }

    private var badges: [PopoverTab: TabBadge] {
        var result: [PopoverTab: TabBadge] = [:]
        for tab in visibleTabs {
            result[tab] = TabBadge.resolve(
                state: paneState(tab),
                count: rowCount(tab),
                hasRoutedFailure: !PopoverBanner.forPane(tab, from: activeBanners).isEmpty
            )
        }
        return result
    }

    /// Counts the user's own open list, not the merged and team sections
    /// stacked underneath it.
    private func rowCount(_ tab: PopoverTab) -> Int {
        switch tab {
        case .pullRequests: return store.prs.count
        case .jira:         return 0
        }
    }

    private func paneState(_ tab: PopoverTab) -> PaneState {
        switch tab {
        case .pullRequests:
            return PaneState.resolve(
                rowCount: store.prs.count, hiddenCount: store.hiddenCount,
                lastError: store.lastError, lastSuccessfulFetch: store.lastSuccessfulFetch
            )
        case .jira:
            return .empty
        }
    }

    private var activeBanners: Set<PopoverBanner> {
        var active: Set<PopoverBanner> = []
        if notifications.isDenied { active.insert(.notificationsDenied) }
        if store.lastNotificationFailure != nil { active.insert(.notificationFailure) }
        if store.lastShipmentFailure != nil { active.insert(.shipmentFailure) }
        if store.lastDeploymentFailure != nil { active.insert(.deploymentFailure) }
        if store.lastUpdateFailure != nil { active.insert(.branchUpdateFailure) }
        if reviews.lastError != nil { active.insert(.teamLookupFailure) }
        if updates.availableRelease != nil { active.insert(.updateAvailable) }
        if updates.lastInstallFailure != nil { active.insert(.installFailure) }
        return active
    }

    /// Computed rather than read from `\.palette`: a view's own environment read
    /// resolves against what its parent handed down, so publishing and drawing
    /// with the same value in one view means computing it here.
    private var palette: ResolvedPalette {
        paletteInputs.resolved(monochromeEnabled: appearance.monochromeEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if setupFailure == nil {
                PopoverTabBar(tabs: visibleTabs, selection: tabBinding, badges: badges)
            }
            Divider()
            content
            // One global row at most, by priority. The rest are routed into the
            // pane that owns them by `PopoverBanner`.
            if let banner = PopoverBanner.topGlobal(from: activeBanners) {
                Divider()
                globalBanner(banner)
            }
            if let last = store.lastSuccessfulFetch, store.lastError == nil {
                Divider()
                footer(last)
            }
        }
        .frame(width: 380)
        .background { popoverBackground }
        // Hands the resolved palette to every row and banner below.
        .environment(\.palette, palette)
    }

    /// Nothing at all for liquid glass.
    ///
    /// That is the point rather than an oversight: the popover already has one
    /// material of its own, and laying a second over it is what flattened the
    /// vibrancy in three earlier attempts at this. Opaque instead replaces it
    /// outright, which is the only way the palette floor becomes a guarantee —
    /// see `PopoverBackground` for the measurements behind that trade.
    @ViewBuilder
    private var popoverBackground: some View {
        switch appearance.popoverBackground {
        case .liquidGlass: Color.clear
        case .opaque:      Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("My pull requests")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }
            settingsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Everything that is not a pull request.
    ///
    /// A `Menu` rather than a nested `.popover`: popovers inside popovers fight
    /// over who is transient and which one a click outside should dismiss, and
    /// this one is a short list of settings, which is what menus are for.
    private var settingsMenu: some View {
        Menu {
            // The version sits directly above "Check for Updates…" so that item
            // unmistakably means *this app*, and not the branch toggle below it.
            Text(verbatim: "PR Master Tray \(updates.currentVersion)")
            if updates.isChecking {
                Text("Checking for updates…")
            } else {
                Button("Check for Updates…") {
                    Task { await updates.checkNow() }
                }
            }
            // There is no logging anywhere in this app, so a check that keeps
            // failing would otherwise be invisible. It lives here rather than as
            // a popover row because a background failure carries no action, and
            // a genuine outage already shows up in the stale banner.
            if let failure = updates.lastCheckFailure {
                Text(verbatim: "Last check failed — \(failure)")
            }
            Divider()
            // Which organizations and whether private repositories show. Its own
            // window because the organization list is unbounded, and a menu that
            // scrolls is a menu nobody reads.
            Button("Settings…", action: onOpenSettings)
            // Absent under a debug override, where the store has no updater —
            // offering a switch for a feature that cannot run would be a lie.
            if canAutoUpdate {
                Toggle("Auto-update behind branches", isOn: $store.autoUpdateEnabled)
            }
            // Not gated on a debug override: unlike everything else in this menu
            // it neither writes to GitHub nor touches the bundle.
            //
            // Bound through the store rather than to a stored property, because
            // macOS owns this switch — see `LaunchAtLoginStore`.
            Toggle("Open at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            // Only while macOS is actually holding it up. Same shape as the
            // failed-update line above: a state the user cannot otherwise work
            // out, and the one action that resolves it.
            if launchAtLogin.state == .needsApproval {
                Button("Approve in Login Items…") { launchAtLogin.openSystemSettings() }
            }
            if let failure = launchAtLogin.lastFailure {
                Text(verbatim: "Couldn't change it — \(failure)")
            }
            Divider()
            Button("Quit PR Master Tray", action: onQuit)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        // The disclosure chevron doubles the width of a 13pt glyph and says
        // nothing a gear does not already say.
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    // MARK: - Content

    /// A setup failure replaces the whole popover rather than one pane: Teams
    /// and Merged are equally unusable without `gh auth`, so scoping it to Mine
    /// would leave two panes claiming to be empty.
    @ViewBuilder
    private var content: some View {
        if let setup = setupFailure {
            SetupNeededView(title: setup.title, command: setup.command)
        } else {
            switch activeTab {
            case .pullRequests:
                PullRequestsPaneView(
                    store: store, reviews: reviews,
                    canMerge: canMerge, canClose: canClose, canApprove: canApprove,
                    onOpen: onOpen, onMerge: onMerge, onClose: onClose,
                    onOpenShipment: onOpenShipment,
                    onOpenReviewRequest: onOpenReviewRequest,
                    onApproveReviewRequest: onApprove,
                    onOpenSettings: onOpenSettings
                )
            case .jira:
                PaneMessageView(
                    icon: "square.stack.3d.up",
                    title: "Jira isn't set up yet",
                    detail: "Your assigned issues and their pull requests will appear here."
                )
            }
        }
    }

    static func hiddenSummary(_ count: Int) -> String {
        count == 1
            ? "1 pull request is hidden by your settings."
            : "\(count) pull requests are hidden by your settings."
    }

    /// RelativeDateTimeFormatter renders a just-completed fetch as
    /// "in 0 seconds", which reads like a prediction rather than a timestamp.
    static func ago(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        guard elapsed >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Setup failures

    private var setupFailure: (title: String, command: String)? {
        switch store.lastError {
        case .ghNotFound:
            return ("GitHub CLI not found", "brew install gh")
        case .notAuthenticated, .unauthorized:
            return ("Not signed in to GitHub", "gh auth login")
        default:
            return nil
        }
    }

    @ViewBuilder
    private func globalBanner(_ banner: PopoverBanner) -> some View {
        switch banner {
        case .installFailure:
            BannerRowView(
                icon: "arrow.down.circle.fill",
                text: updates.lastInstallFailure ?? ""
            )
        case .updateAvailable:
            BannerRowView(
                icon: "arrow.down.circle.fill",
                text: "Version \(updates.availableRelease?.version ?? "") available",
                isWarning: false,
                actionTitle: updates.canInstall ? "Update" : nil,
                action: { Task { await updates.install() } },
                isBusy: updates.isInstalling
            )
        case .notificationsDenied:
            BannerRowView(
                icon: "bell.slash.fill",
                text: "Notifications are turned off",
                actionTitle: "Open Settings",
                action: Self.openNotificationSettings
            )
        default:
            EmptyView()
        }
    }

    /// Opens the Notifications pane of System Settings.
    ///
    /// The identifier is the pre-Ventura one on purpose: the settings extension
    /// still declares it as its `legacyBundleIdentifier`, and it is the form
    /// that works across the macOS versions this app runs on.
    private static func openNotificationSettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.notifications"
        )!)
    }

    // MARK: - Footer

    /// Only the timestamp lives here now. Rendered by the caller solely when
    /// there is a timestamp to show, so the popover never ends on an empty bar.
    private func footer(_ last: Date) -> some View {
        HStack {
            Text(verbatim: "Updated \(Self.ago(last))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            // So a shorter list than expected has a visible reason, rather than
            // the user wondering where a pull request went.
            if store.hiddenCount > 0 {
                Text(verbatim: "\(store.hiddenCount) hidden")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(Self.hiddenSummary(store.hiddenCount))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Full-popover state for a problem the user must fix before anything works.
struct SetupNeededView: View {
    let title: String
    let command: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(palette.color(.orange))
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("Run this in a terminal:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // The exact command, selectable so it can be copied verbatim.
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
    }
}
