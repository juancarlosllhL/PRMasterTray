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
/// Two tabs, because those are two unrelated jobs. Which pull requests exist has
/// nothing to do with what colour they are, and the appearance controls arrived
/// last, which had them sitting underneath an organization list of unbounded
/// length — the one place in the window nobody scrolls to.
struct SettingsView: View {
    @Bindable var store: PRStore
    @Bindable var appearance: AppearanceStore

    private enum Tab: String {
        case pullRequests, appearance
    }

    /// Only ever moved by a click, except under `PRMASTER_SETTINGS_TAB`, which is
    /// how the appearance tab gets screenshotted at all.
    @State private var tab: Tab = Debug.settingsTab.flatMap(Tab.init(rawValue:)) ?? .pullRequests

    var body: some View {
        TabView(selection: $tab) {
            pullRequests
                .tabItem { Label("Pull Requests", systemImage: "arrow.triangle.pull") }
                .tag(Tab.pullRequests)
            appearanceSettings
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(Tab.appearance)
        }
        // A fixed height rather than one per tab. Both would be native — System
        // Settings resizes per pane — but this panel is small enough that the
        // window jumping every time you switch tabs reads as a glitch. Tall
        // enough for the appearance tab not to look padded out, and it caps the
        // organization list, which scrolls inside from there rather than growing
        // the window past the screen.
        .frame(width: 440, height: 430)
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
                Text(verbatim: privateSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.knownOrganizations.isEmpty {
                    Text("No organizations yet — they appear here as soon as your pull requests load.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    organizationList
                }
            } header: {
                Text("Organizations")
            } footer: {
                // The one thing about this window that is not self-evident, and
                // the thing a user would be annoyed to discover by accident.
                Text("Hidden pull requests are left out of the menu bar count, never notify, and are never brought up to date automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// How those pull requests are drawn.
    private var appearanceSettings: some View {
        Form {
            // Its own section because it is the only control here that is not
            // about the popover: the theme also reaches this window and the merge
            // confirmation, so filing it under a "Popover" header would be a lie.
            Section {
                Picker("Theme", selection: $appearance.theme) {
                    Text("System").tag(AppTheme.system)
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Theme")
            }

            Section {
                Picker("Background", selection: $appearance.popoverBackground) {
                    Text("Liquid glass").tag(PopoverBackground.liquidGlass)
                    Text("Opaque").tag(PopoverBackground.opaque)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Popover background")
            } footer: {
                // The one thing a user cannot discover by looking: liquid glass
                // is prettier and measurably less legible, and which of those
                // matters more is theirs to decide, not ours. Said in terms of
                // what they will see rather than in contrast ratios.
                Text("Liquid glass lets the desktop through, the way a macOS popover normally does. Over a window that strongly contrasts with it, the status colours get harder to read — Opaque fixes the background so they stay legible whatever is behind.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                Text("Monochrome drops the status colours and leans on each row's icon and label instead. It also turns on by itself when macOS is set to differentiate without colour.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
