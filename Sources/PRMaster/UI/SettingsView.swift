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
/// Split by job, not by store. Appearance arrived last and would otherwise sit
/// under an organization list of unbounded length — the one place nobody scrolls.
struct SettingsView: View {
    @Bindable var store: PRStore
    @Bindable var reviews: ReviewStore
    @Bindable var appearance: AppearanceStore
    @Bindable var jira: JiraAccountStore
    @Bindable var jiraStore: JiraStore

    private enum Tab: String {
        case pullRequests, teams, jira, appearance
    }

    /// Only ever moved by a click, except under `PRMASTER_SETTINGS_TAB`, which is
    /// how the appearance tab gets screenshotted at all.
    @State private var tab: Tab = Debug.settingsTab.flatMap(Tab.init(rawValue:)) ?? .pullRequests

    var body: some View {
        TabView(selection: $tab) {
            pullRequests
                .tabItem { Label("Pull Requests", systemImage: "arrow.triangle.pull") }
                .tag(Tab.pullRequests)
            teamSettings
                .tabItem { Label("Teams", systemImage: "person.2") }
                .tag(Tab.teams)
            jiraSettings
                .tabItem { Label("Jira", systemImage: "square.stack.3d.up") }
                .tag(Tab.jira)
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

                Picker("Keep merged ones for", selection: $store.mergedWindow) {
                    ForEach(MergedWindow.allCases, id: \.self) { window in
                        Text(verbatim: window.label).tag(window)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Timing")
            } footer: {
                // The one thing neither picker can say for itself, and the reason
                // a well-tended branch still goes stale.
                footnote(Text("Both are measured from when a pull request was opened or merged, not from its last activity."))
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
                footnote(Text("Hidden pull requests are left out of the menu bar count, never notify, and are never brought up to date."))
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Which of the user's teams the popover lists review requests for.
    private var teamSettings: some View {
        Form {
            Section {
                Picker("Show requests opened within", selection: $reviews.window) {
                    ForEach(ReviewWindow.allCases, id: \.self) { window in
                        Text(verbatim: window.label).tag(window)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Waiting on your teams")
            } footer: {
                // Measured from opening rather than from last activity, which is
                // the whole reason the list is short: teams accumulate hundreds of
                // forgotten bot pull requests that keep touching themselves.
                footnote(Text("Measured from when a pull request was opened, so abandoned ones drop out by themselves."))
            }

            Section {
                if reviews.teams.isEmpty {
                    footnote(Text("No teams yet — they appear as soon as GitHub answers. If they never do, this needs the read:org scope: gh auth refresh -s read:org"))
                } else {
                    teamList
                }
            } header: {
                Text("Teams")
            } footer: {
                footnote(Text(verbatim: teamSummary))
                // The one thing a user would otherwise discover by being annoyed:
                // the button in this section is not a private bookmark.
                footnote(Text("**Approve** posts a public review under your own name, after a confirmation."))
            }

            Section {
                Toggle("Comment something funny when approving", isOn: $reviews.approvalQuipsEnabled)
            } footer: {
                footnote(Text("The confirmation shows the remark before anything is posted."))
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// One switch per team, checked when its review requests are listed.
    ///
    /// Not a `List`, for the reason the organization list is not one either: a
    /// nested `List` inside a grouped `Form` brings its own selection and
    /// background, and this is a column of checkboxes.
    private var teamList: some View {
        ForEach(reviews.teams) { team in
            Toggle(isOn: binding(for: team)) {
                HStack(spacing: 6) {
                    // verbatim: a team name is user content, and a literal
                    // interpolation would be read as a format string.
                    Text(verbatim: team.name)
                    Spacer(minLength: 8)
                    Text(verbatim: waitingLabel(for: team))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Reads and writes through `ReviewStore.teamFilter`, so flipping a switch
    /// persists it and refetches in one step.
    private func binding(for team: Team) -> Binding<Bool> {
        Binding(
            get: { reviews.teamFilter.shows(team) },
            set: { reviews.teamFilter.set(team, shown: $0) }
        )
    }

    /// GitHub's own count for that team, which is why it keeps making sense while
    /// the team is switched off — the search asks for a disabled team's count
    /// precisely so this row can be honest. Absent means GitHub has not answered
    /// yet, which is not the same as none.
    private func waitingLabel(for team: Team) -> String {
        guard let count = reviews.pendingCount(for: team) else { return "—" }
        return count == 1 ? "1 waiting" : "\(count) waiting"
    }

    /// Says what the tab is worth right now, the same way the other tabs' footers
    /// do — a section with nothing in it is the difference between a setting that
    /// does nothing and one somebody is looking for.
    private var teamSummary: String {
        guard reviews.window != .off else {
            return "The section is switched off, so nothing your teams are asked to review is listed."
        }
        let count = reviews.visible(under: store.filter).count
        switch count {
        case 0: return "Nothing is waiting on your teams inside this window."
        case 1: return "1 pull request is listed right now."
        default: return "\(count) pull requests are listed right now."
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

                Toggle("Hide emoji in titles", isOn: $appearance.hidesEmoji)
            } footer: {
                // The one thing a user cannot discover by looking: liquid glass
                // is prettier and measurably less legible, and which of those
                // matters more is theirs to decide, not ours. Said in terms of
                // what they will see rather than in contrast ratios.
                footnote(Text("Liquid glass lets the desktop through. Opaque keeps the status colours legible whatever is behind."))
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
                footnote(Text("Turns on by itself when macOS is set to differentiate without colour."))
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Sign-in rather than preferences, which is why it has a button at all
    /// while every other tab writes through on the spot: a half-typed token is
    /// not a state worth saving.
    private static let apiTokenURL = URL(
        string: "https://id.atlassian.com/manage-profile/security/api-tokens"
    )!

    private var jiraSettings: some View {
        Form {
            Section {
                LabeledContent("Site") {
                    TextField("", text: $jira.site,
                              prompt: Text(verbatim: "https://acme.atlassian.net"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("Email") {
                    TextField("", text: $jira.email,
                              prompt: Text(verbatim: "you@company.com"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent {
                    SecureField("", text: $jira.apiToken,
                                prompt: Text(verbatim: "Paste your token"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                } label: {
                    HStack(spacing: 4) {
                        Text("API token")
                        Link(destination: Self.apiTokenURL) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help("Create an API token at id.atlassian.com")
                        .accessibilityLabel("Create an API token")
                    }
                }

                LabeledContent("") {
                    HStack(spacing: 8) {
                        Button(jira.isConfigured ? "Test and Update" : "Test and Save") {
                            Task { await jira.testAndSave() }
                        }
                        .disabled(jira.signInState.isBusy)
                        .keyboardShortcut(.defaultAction)

                        if jira.signInState.isBusy {
                            ProgressView().controlSize(.small)
                        }
                        if jira.isConfigured {
                            Button("Sign Out") { jira.signOut() }
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let name = jira.signInState.succeededName {
                    LabeledContent("") {
                        statusLine("checkmark.circle.fill", "Signed in as \(name)")
                    }
                }
                if let failure = jira.signInState.failureMessage {
                    LabeledContent("") {
                        statusLine("exclamationmark.triangle.fill", failure)
                    }
                }
            } header: {
                Text("Jira account")
            } footer: {
                footnote(Text("Nothing is saved until it has been tested."))
            }

            Section {
                Picker("Show issues as", selection: $jiraStore.layout) {
                    ForEach(JiraLayout.allCases, id: \.self) { layout in
                        Text(verbatim: layout.label).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Layout")
            } footer: {
                footnote(Text(verbatim: jiraLayoutSummary))
            }

            Section {
                Picker("Show issues finished within", selection: $jiraStore.window) {
                    ForEach(JiraWindow.allCases, id: \.self) { window in
                        Text(verbatim: window.label).tag(window)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Done")
            } footer: {
                footnote(Text(verbatim: jiraDoneSummary))
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var jiraLayoutSummary: String {
        JiraBoard.layoutSummary(jiraStore.layout, columns: jiraStore.boardColumns.count)
    }

    /// Says what the window is worth right now rather than in the abstract,
    /// the shape every other footer in this window uses.
    private var jiraDoneSummary: String {
        guard jiraStore.window != .off else {
            return "Finished issues are hidden. To do and In progress still show."
        }
        let count = jiraStore.groups.done.count
        let shown = count == 1 ? "1 issue" : "\(count) issues"
        return "Measured from when an issue moved to Done. \(shown) would show right now."
    }

    private func statusLine(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(verbatim: text)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
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
