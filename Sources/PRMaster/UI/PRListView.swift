import SwiftUI
import PRMasterCore

struct PRListView: View {
    @Bindable var store: PRStore
    let onOpen: (PullRequest) -> Void
    let onMerge: (PullRequest) -> Void
    let onClose: (PullRequest) -> Void
    /// Opens whatever the row is about: the pipeline while it runs, the release
    /// once there is one.
    let onOpenShipment: (Shipment) -> Void
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

    /// Computed rather than read from `\.palette`: a view's own environment read
    /// resolves against what its parent handed down, so publishing and drawing
    /// with the same value in one view means computing it here.
    private var palette: ResolvedPalette {
        paletteInputs.resolved(monochromeEnabled: appearance.monochromeEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            // Outside `content` on purpose: a day with nothing open but
            // something merged is exactly when this section is worth having,
            // and putting it inside would hide it behind the empty state.
            if !store.shipments.isEmpty {
                Divider()
                mergedSection
            }
            // A denied permission silently disables the whole point of the
            // app, so it gets a permanent row rather than a transient hint.
            if notifications.isDenied {
                Divider()
                notificationsDisabledRow
            } else if let failure = store.lastNotificationFailure {
                Divider()
                warningRow(
                    icon: "bell.badge.slash",
                    text: "Couldn't show a notification — \(failure). Retrying."
                )
            }
            // Not retried while the head commit is unchanged, so without this
            // the PR would just sit there behind its base branch, silently.
            if let failure = store.lastShipmentFailure {
                Divider()
                warningRow(
                    icon: "shippingbox",
                    text: "Couldn't check what shipped — \(failure)"
                )
            }
            // Its own row rather than the one above, and worth one at all because
            // the alternative is indistinguishable from a repository that deploys
            // nowhere: an unauthorized token, a rate-limited code search and an
            // SSO refusal all end with the chips simply not appearing.
            if let failure = store.lastDeploymentFailure {
                Divider()
                warningRow(
                    icon: "square.stack.3d.up",
                    text: "Couldn't check stg and prod — \(failure)"
                )
            }
            if let failure = store.lastUpdateFailure {
                Divider()
                warningRow(
                    icon: "arrow.triangle.pull",
                    text: "Couldn't update a branch — \(failure)"
                )
            }
            // A new version is good news, not a warning, so it gets its own
            // colour and an action rather than joining the orange band below.
            if let release = updates.availableRelease {
                Divider()
                updateRow(release)
            }
            // The user clicked Update and it did not happen, so this is the one
            // update failure that earns a permanent row. The message is already
            // a full sentence from PRMasterError, so it is shown as-is.
            if let failure = updates.lastInstallFailure {
                Divider()
                warningRow(
                    icon: "arrow.down.circle.fill",
                    text: failure
                )
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

    @ViewBuilder
    private var content: some View {
        // A setup failure replaces the whole list: there is nothing to show
        // and the user cannot proceed until they act on it.
        if let setup = setupFailure {
            SetupNeededView(title: setup.title, command: setup.command)
        } else if store.prs.isEmpty, let error = store.lastError {
            // With no data to fall back on there is no stale banner to carry
            // the message, so the failure has to be the content itself —
            // otherwise a first-fetch failure just spins on "Loading…".
            message(
                icon: "exclamationmark.triangle",
                title: "Couldn't reach GitHub",
                detail: error.localizedDescription
            )
        } else if store.prs.isEmpty && store.lastSuccessfulFetch != nil {
            emptyState
        } else if store.prs.isEmpty {
            loadingState
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if let banner = staleBanner {
                staleBannerView(banner)
                Divider()
            }
            // A ScrollView is greedy and would leave dead space below a short
            // list, so only reach for one when the list is genuinely long.
            if store.prs.count > Self.rowsBeforeScrolling {
                ScrollView {
                    rows
                }
                .frame(height: 460)
            } else {
                rows
            }
        }
    }

    private static let rowsBeforeScrolling = 8

    private var rows: some View {
        // One clock read for the whole list, so every row is measured against the
        // same instant. Read here rather than held on the store: staleness is a
        // pure function of the threshold and the time, so there is no derived
        // state to keep in step — and reading `store.staleThreshold` inside the
        // body is what lets `@Observable` re-mark the list the moment the
        // settings picker moves, with no refetch.
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

    /// "No open pull requests" would be a lie when the filter is what emptied
    /// the list — and a lie the app could keep telling for weeks, since a hidden
    /// PR produces no notification either.
    @ViewBuilder
    private var emptyState: some View {
        if store.hiddenCount > 0 {
            VStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text("Nothing to show").font(.system(size: 12, weight: .medium))
                Text(verbatim: Self.hiddenSummary(store.hiddenCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Settings…", action: onOpenSettings)
                    .font(.system(size: 11))
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            message(icon: "checkmark.circle", title: "No open pull requests",
                    detail: "Nothing of yours is waiting to merge.")
        }
    }

    static func hiddenSummary(_ count: Int) -> String {
        count == 1
            ? "1 pull request is hidden by your settings."
            : "\(count) pull requests are hidden by your settings."
    }

    private var loadingState: some View {
        message(icon: "arrow.triangle.pull", title: "Loading…", detail: nil)
    }

    private func message(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Recently merged

    private var mergedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recently merged")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

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

    private static let mergedRowsBeforeScrolling = 5

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

    // MARK: - Stale banner

    /// Shown when the list is real but out of date, so a failed refresh is
    /// visible rather than silently showing yesterday's state as current.
    private var staleBanner: String? {
        guard let error = store.lastError else { return nil }
        guard let last = store.lastSuccessfulFetch else { return error.localizedDescription }
        return "Couldn't refresh · updated \(Self.ago(last)) · \(error.localizedDescription)"
    }

    private func staleBannerView(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.color(.orange))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.wash(.orange))
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

    // MARK: - App update

    /// Offers to replace the app with a newer release.
    ///
    /// Blue rather than the orange used for failures: this is information with
    /// an action attached, not something that went wrong.
    private func updateRow(_ release: AppRelease) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(palette.color(.blue))
            // A release tag is whatever was pushed, so it is never interpolated
            // into a localised format string.
            Text(verbatim: "Version \(release.version) available")
                .font(.system(size: 11))
            Spacer(minLength: 0)
            if updates.isInstalling {
                ProgressView().controlSize(.small)
            } else if updates.canInstall {
                Button("Update") {
                    Task { await updates.install() }
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.wash(.blue))
    }

    private func warningRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(palette.color(.orange))
            Text(verbatim: text).font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.wash(.orange))
    }

    /// The row was already clickable end to end, but nothing about it said so:
    /// an orange band of text reads as a complaint, not as an offer to fix it.
    /// So it takes the same shape as the update row — what happened, and a
    /// button that does something about it.
    private var notificationsDisabledRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.slash.fill").foregroundStyle(palette.color(.orange))
            Text("Notifications are turned off")
                .font(.system(size: 11))
            Spacer(minLength: 0)
            Button("Open Settings", action: Self.openNotificationSettings)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.wash(.orange))
        .help("PR Master Tray can't tell you a pull request is ready until you allow its notifications.")
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
