import SwiftUI
import PRMasterCore

struct JiraPaneView: View {
    let jira: JiraStore
    let filter: PRFilter
    let onOpenIssue: (JiraIssue) -> Void
    let onOpenLink: (LinkedPullRequest) -> Void
    let onOpenSettings: () -> Void

    @FocusState private var isSearchFocused: Bool

    private var query: Binding<String> {
        Binding { jira.searchQuery } set: { jira.searchQuery = $0 }
    }

    private var isSearching: Bool {
        !jira.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if jira.isConfigured && !jira.issues.isEmpty {
                searchField
                Divider()
            }
            if let failure = jira.lastLinkFailure {
                BannerRowView(
                    icon: "arrow.triangle.pull",
                    text: "Couldn't check for pull requests — \(failure)"
                )
            }
            content
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter by key or summary", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)
                .onSubmit { isSearchFocused = false }
            if isSearching {
                Button {
                    jira.searchQuery = ""
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Counted from the groups, not the fetch: a pane counting rows it then
    /// drops as parked or out of window would render nothing at all.
    private var state: PaneState {
        let shown = jira.visibleGroups.count
        return PaneState.resolve(
            rowCount: shown,
            hiddenCount: jira.issues.count - shown,
            lastError: jira.lastError,
            lastSuccessfulFetch: jira.lastSuccessfulFetch
        )
    }

    @ViewBuilder
    private var content: some View {
        if !jira.isConfigured {
            PaneMessageView(
                icon: "square.stack.3d.up",
                title: "Jira isn't set up yet",
                detail: "Add your site, email and an API token to see the issues assigned to you.",
                actionTitle: "Settings…",
                action: onOpenSettings
            )
        } else {
            switch state {
            case .loading:
                PaneMessageView(icon: "square.stack.3d.up", title: "Loading…")
            case .failed:
                PaneMessageView(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't reach Jira",
                    detail: jira.lastError?.localizedDescription,
                    actionTitle: "Settings…",
                    action: onOpenSettings
                )
            case .empty:
                PaneMessageView(
                    icon: "checkmark.circle",
                    title: "Nothing assigned to you",
                    detail: "No Jira issue is assigned to you and still open."
                )
            case .emptyByFilter where isSearching:
                PaneMessageView(
                    icon: "magnifyingglass",
                    title: "No issue matches",
                    detail: "Nothing assigned to you matches “\(jira.searchQuery)”.",
                    actionTitle: "Clear the filter",
                    action: { jira.searchQuery = "" }
                )
            case .emptyByFilter:
                PaneMessageView(
                    icon: "checkmark.circle",
                    title: "Nothing to show",
                    detail: "Everything assigned to you is parked or finished "
                        + "outside the window on the Jira settings tab."
                )
            case .content, .stale:
                rows
            }
        }
    }

    private struct Section {
        let title: String
        let issues: [JiraIssue]
        let cap: Int
        let height: CGFloat
        var showsPriority = false
    }

    private var sections: [Section] {
        let groups = jira.visibleGroups
        return [
            Section(
                title: "In progress", issues: groups.inProgress,
                cap: 5, height: 260, showsPriority: true
            ),
            Section(
                title: "Testing", issues: groups.testing,
                cap: 4, height: 180, showsPriority: true
            ),
            Section(
                title: "To do", issues: groups.toDo,
                cap: 5, height: 220, showsPriority: true
            ),
            Section(title: "Done", issues: groups.done, cap: 4, height: 180),
        ].filter { !$0.issues.isEmpty }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.title) { index, section in
                if index > 0 { Divider() }
                self.section(section)
            }
        }
    }

    /// Its own scroll per section, capped like the pull request sections, so a
    /// long list of one kind cannot push the others off the popover.
    @ViewBuilder
    private func section(_ section: Section) -> some View {
        PaneHeaderView(title: section.title, trailing: "\(section.issues.count)")
        if section.issues.count > section.cap {
            ScrollView { issueRows(section.issues, showsPriority: section.showsPriority) }
                .frame(height: section.height)
        } else {
            issueRows(section.issues, showsPriority: section.showsPriority)
        }
    }

    private func issueRows(_ issues: [JiraIssue], showsPriority: Bool) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(issues) { issue in
                JiraIssueRowView(
                    issue: issue,
                    links: jira.links(for: issue.key, under: filter),
                    linkState: jira.linkState(for: issue.key),
                    isExpanded: jira.expandedKeys.contains(issue.key),
                    showsPriority: showsPriority,
                    onToggle: { jira.toggle(issue.key) },
                    onOpenIssue: { onOpenIssue(issue) },
                    onOpenLink: onOpenLink
                )
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}
