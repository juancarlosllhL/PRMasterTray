import SwiftUI
import PRMasterCore

/// Chooses which pull requests the app cares about, and how it draws them.
///
/// A window rather than more rows in the gear menu: the organization list is as
/// long as the user's GitHub life is wide, and a menu that scrolls is a menu
/// nobody reads. Every control here writes straight through to `PRStore.filter`
/// or `AppearanceStore`, both of which persist and take effect on the spot — so
/// there is no Save button, and nothing to undo but the switch itself.
///
/// Three tabs, because those are three unrelated jobs. Which pull requests exist
/// has nothing to do with what colour they are, and the appearance controls
/// arrived last, which had them sitting underneath an organization list of
/// unbounded length — the one place in the window nobody scrolls to. Merged gets
/// its own rather than joining Pull Requests: everything on that tab is about
/// what is still open, and burying the one control about what already shipped at
/// the bottom of it would be the same mistake again.
struct SettingsView: View {
    @Bindable var store: PRStore
    @Bindable var appearance: AppearanceStore

    private enum Tab: String {
        case pullRequests, merged, appearance
    }

    /// Only ever moved by a click, except under `PRMASTER_SETTINGS_TAB`, which is
    /// how the appearance tab gets screenshotted at all.
    @State private var tab: Tab = Debug.settingsTab.flatMap(Tab.init(rawValue:)) ?? .pullRequests

    var body: some View {
        TabView(selection: $tab) {
            pullRequests
                .tabItem { Label("Pull Requests", systemImage: "arrow.triangle.pull") }
                .tag(Tab.pullRequests)
            mergedSettings
                .tabItem { Label("Merged", systemImage: "shippingbox") }
                .tag(Tab.merged)
            appearanceSettings
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(Tab.appearance)
        }
        // A fixed height rather than one per tab. Both would be native — System
        // Settings resizes per pane — but this panel is small enough that the
        // window jumping every time you switch tabs reads as a glitch.
        //
        // Sized so the appearance tab fits without scrolling, which it did not at
        // 440x430 — a scrollbar over two short sections made the window look full
        // when it was only too small — and without leaving a cavern under it
        // either. On the other tab the slack is the point: it is room for the
        // organization list to grow into before it starts scrolling.
        .frame(width: 520, height: 470)
    }

    /// Which pull requests the app cares about.
    private var pullRequests: some View {
        Form {
            Section {
                Toggle(
                    "Show pull requests from private repositories",
                    isOn: $store.filter.showsPrivateRepositories
                )
            } header: {
                Text("Repositories")
            } footer: {
                // Says what the switch is actually worth right now — "0 of your
                // open pull requests" is the difference between a setting that
                // does nothing and one the user is looking for.
                footnote(Text(verbatim: privateSummary))
            }

            Section {
                Picker("Mark as stale after", selection: $store.staleThreshold) {
                    ForEach(StaleThreshold.allCases, id: \.self) { threshold in
                        // verbatim for consistency with the rest of the window,
                        // though these labels are ours rather than user content.
                        Text(verbatim: threshold.label).tag(threshold)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Stale pull requests")
            } footer: {
                // Two things a user cannot work out by looking, and the second is
                // the one they would otherwise discover by being annoyed: this
                // marks rows, it does not quietly change what the app acts on.
                footnote(Text("Measured from when a pull request was opened, not from its last activity, so keeping a branch up to date doesn't reset it. Stale pull requests still notify and are still brought up to date — the marker only adds a way to close them."))
            }

            Section {
                if store.knownOrganizations.isEmpty {
                    footnote(Text("No organizations yet — they appear here as soon as your pull requests load."))
                } else {
                    organizationList
                }
            } header: {
                Text("Organizations")
            } footer: {
                // The one thing about this window that is not self-evident, and
                // the thing a user would be annoyed to discover by accident.
                footnote(Text("Hidden pull requests are left out of the menu bar count, never notify, and are never brought up to date automatically."))
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// What happens to them after they are merged.
    private var mergedSettings: some View {
        Form {
            Section {
                Picker("Keep merged pull requests for", selection: $store.mergedWindow) {
                    ForEach(MergedWindow.allCases, id: \.self) { window in
                        Text(verbatim: window.label).tag(window)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Recently merged")
            } footer: {
                // Three things a user cannot work out by looking: where the
                // section is, what the version actually means, and that Off is
                // how you get rid of it.
                footnote(Text("The popover lists what you merged inside this window and what became of it — its pipeline still building, the check that failed, or the version it went out in. Measured from when a pull request was merged, so the section empties itself on this schedule. Off hides it entirely."))
            }

            Section {
                footnote(Text(verbatim: versionSummary))
            } header: {
                Text("About the version")
            } footer: {
                // The claim this feature must not overstate. Said plainly here
                // because it is the one thing somebody could act on wrongly.
                footnote(Text("A version means the release whose tag contains your merge commit — that it was cut, not that it reached staging or production. Repositories that cut no releases show how their checks did and nothing more."))
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Says what the setting is worth right now, the same way the private
    /// repositories footer does — a window with nothing in it is the difference
    /// between a setting that does nothing and one somebody is looking for.
    private var versionSummary: String {
        guard store.mergedWindow != .off else {
            return "The section is switched off, so nothing merged is listed."
        }
        let count = store.shipments.count
        switch count {
        case 0: return "Nothing of yours has merged inside this window."
        case 1: return "1 merged pull request is listed right now."
        default: return "\(count) merged pull requests are listed right now."
        }
    }

    /// How those pull requests are drawn.
    private var appearanceSettings: some View {
        Form {
            // Deliberately unheaded. A "Theme" header over a row already labelled
            // Theme just stutters, and no shorter word covers both of these
            // honestly: the theme reaches this window and the merge confirmation
            // as well, while the background is the popover alone. The tab is
            // called Appearance, which is the header this group would want.
            Section {
                Picker("Theme", selection: $appearance.theme) {
                    Text("System").tag(AppTheme.system)
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)

                Picker("Background", selection: $appearance.popoverBackground) {
                    Text("Liquid glass").tag(PopoverBackground.liquidGlass)
                    Text("Opaque").tag(PopoverBackground.opaque)
                }
                .pickerStyle(.segmented)
            } footer: {
                // The one thing a user cannot discover by looking: liquid glass
                // is prettier and measurably less legible, and which of those
                // matters more is theirs to decide, not ours. Said in terms of
                // what they will see rather than in contrast ratios.
                footnote(Text("Liquid glass lets the desktop through, the way a macOS popover normally does. Over a window that strongly contrasts with it, the status colours get harder to read — Opaque fixes the background so they stay legible whatever is behind."))
            }

            Section {
                Toggle("High-contrast monochrome", isOn: $appearance.monochromeEnabled)
            } header: {
                Text("Accessibility")
            } footer: {
                // Names the one confusing state this design allows: the switch
                // reading off while the app draws monochrome, because macOS asked
                // and a local preference does not override an accessibility
                // setting.
                footnote(Text("Monochrome drops the status colours and leans on each row's icon and label instead. It also turns on by itself when macOS is set to differentiate without colour."))
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Secondary copy — footers, and the empty-organizations line.
    ///
    /// Both alignment modifiers are load-bearing, not belt-and-braces. The
    /// default alignment of a grouped `Form` footer is not stable across SDKs:
    /// v0.4.1 shipped from CI against the macOS 15 SDK and ranged these
    /// paragraphs *right*, while a local build of the identical commit against
    /// the macOS 26 SDK ranged them left. Stating it makes both agree, and is
    /// the only version of this that can be verified from either machine.
    private func footnote(_ text: Text) -> some View {
        text
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One switch per organization, checked when its pull requests are shown.
    ///
    /// Deliberately not a `List`: inside a grouped `Form` a nested `List` brings
    /// its own selection and background, and this is a column of checkboxes.
    private var organizationList: some View {
        ForEach(store.knownOrganizations, id: \.self) { organization in
            Toggle(isOn: binding(for: organization)) {
                HStack(spacing: 6) {
                    // verbatim: an organization name is user content, and a
                    // literal interpolation would be read as a format string.
                    Text(verbatim: organization)
                    Spacer(minLength: 8)
                    Text(verbatim: countLabel(for: organization))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Reads and writes through `PRStore.filter`, so flipping a switch persists
    /// the change and re-filters the list in one step.
    private func binding(for organization: String) -> Binding<Bool> {
        Binding(
            get: { store.filter.shows(organization: organization) },
            set: { store.filter.setOrganization(organization, shown: $0) }
        )
    }

    /// Counted from the *unfiltered* snapshot: the number has to keep making
    /// sense while the organization it describes is switched off.
    private func countLabel(for organization: String) -> String {
        let count = store.allPRs.filter { $0.organization == organization }.count
        return count == 1 ? "1 open" : "\(count) open"
    }

    private var privateSummary: String {
        let count = store.allPRs.filter(\.isPrivate).count
        switch count {
        case 0: return "None of your open pull requests are in private repositories."
        case 1: return "1 of your open pull requests is in a private repository."
        default: return "\(count) of your open pull requests are in private repositories."
        }
    }
}
