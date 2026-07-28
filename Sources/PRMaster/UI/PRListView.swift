import SwiftUI
import PRMasterCore

struct PRListView: View {
    @Bindable var store: PRStore
    let onOpen: (PullRequest) -> Void
    let onMerge: (PullRequest) -> Void
    let onQuit: () -> Void
    /// False while a debug override is active, so the app never offers an
    /// action it is going to refuse.
    let canMerge: Bool
    /// Also false under a debug override, where the store has no updater at
    /// all — offering a switch for a feature that cannot run would be a lie.
    let canAutoUpdate: Bool
    @Bindable var notifications: NotificationStatus
    /// App-update state. Nothing to bind to — every property is read-only — so a
    /// plain `let` is enough; `@Observable` tracks the reads either way.
    let updates: AppUpdateStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
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
            Text(verbatim: "PRMaster \(updates.currentVersion)")
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
            // Absent under a debug override, where the store has no updater —
            // offering a switch for a feature that cannot run would be a lie.
            if canAutoUpdate {
                Toggle("Auto-update behind branches", isOn: $store.autoUpdateEnabled)
            }
            Divider()
            Button("Quit PRMaster", action: onQuit)
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
        LazyVStack(spacing: 2) {
            ForEach(store.prs) { pr in
                PRRowView(
                    pr: pr,
                    canMerge: canMerge,
                    isUpdating: store.updatingIDs.contains(pr.id),
                    onOpen: { onOpen(pr) },
                    onMerge: { onMerge(pr) }
                )
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        message(icon: "checkmark.circle", title: "No open pull requests",
                detail: "Nothing of yours is waiting to merge.")
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
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
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
                .foregroundStyle(.blue)
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
        .background(Color.blue.opacity(0.10))
    }

    private func warningRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(verbatim: text).font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
    }

    private var notificationsDisabledRow: some View {
        Button {
            NSWorkspace.shared.open(URL(
                string: "x-apple.systempreferences:com.apple.preference.notifications"
            )!)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                Text("Notifications disabled — open System Settings")
                    .font(.system(size: 11))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Full-popover state for a problem the user must fix before anything works.
struct SetupNeededView: View {
    let title: String
    let command: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
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
