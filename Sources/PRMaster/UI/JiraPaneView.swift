import SwiftUI
import PRMasterCore

struct JiraPaneView: View {
    let jira: JiraStore
    let filter: PRFilter
    let onOpenIssue: (JiraIssue) -> Void
    let onOpenLink: (LinkedPullRequest) -> Void
    let onOpenSettings: () -> Void

    private static let rowsBeforeScrolling = 6

    var body: some View {
        VStack(spacing: 0) {
            if let failure = jira.lastLinkFailure {
                BannerRowView(
                    icon: "arrow.triangle.pull",
                    text: "Couldn't check for pull requests — \(failure)"
                )
            }
            PaneHeaderView(title: "Assigned to you")
            content
        }
    }

    private var state: PaneState {
        PaneState.resolve(
            rowCount: jira.issues.count,
            hiddenCount: 0,
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
            case .empty, .emptyByFilter:
                PaneMessageView(
                    icon: "checkmark.circle",
                    title: "Nothing assigned to you",
                    detail: "No Jira issue is assigned to you and still open."
                )
            case .content, .stale:
                rows
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        if jira.issues.count > Self.rowsBeforeScrolling {
            ScrollView { issueRows }
                .frame(height: 320)
        } else {
            issueRows
        }
    }

    private var issueRows: some View {
        LazyVStack(spacing: 2) {
            ForEach(jira.issues) { issue in
                JiraIssueRowView(
                    issue: issue,
                    links: jira.links(for: issue.key, under: filter),
                    linkState: jira.linkState(for: issue.key),
                    isExpanded: jira.expandedKeys.contains(issue.key),
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
