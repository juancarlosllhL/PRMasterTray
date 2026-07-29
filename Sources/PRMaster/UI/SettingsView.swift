import SwiftUI
import PRMasterCore

/// Chooses which pull requests the app cares about.
///
/// A window rather than more rows in the gear menu: the organization list is as
/// long as the user's GitHub life is wide, and a menu that scrolls is a menu
/// nobody reads. Every control here writes straight through to `PRStore.filter`,
/// which persists and re-filters on the spot — so there is no Save button, and
/// nothing to undo but the switch itself.
struct SettingsView: View {
    @Bindable var store: PRStore

    var body: some View {
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
        .frame(width: 420)
        // Tall enough that one organization does not look like a mistake, capped
        // so a busy account cannot grow the window past the screen — the form
        // scrolls inside it from there.
        .frame(minHeight: 240, maxHeight: 520)
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
