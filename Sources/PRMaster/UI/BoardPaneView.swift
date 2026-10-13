import SwiftUI
import PRMasterCore

struct BoardPaneView: View {
    let board: BoardStore
    let filter: PRFilter
    let onOpenCard: (BoardCard) -> Void
    let cardLink: (BoardCard) -> URL?
    let jiraKeyLink: (String) -> URL?
    let onOpenJiraLink: (URL) -> Void
    let onOpenLink: (LinkedPullRequest) -> Void
    let onOpenSettings: () -> Void

    @FocusState private var isSearchFocused: Bool

    private var query: Binding<String> {
        Binding { board.searchQuery } set: { board.searchQuery = $0 }
    }

    private var isSearching: Bool {
        !board.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasFetchedAnything: Bool {
        !board.jira.issues.isEmpty || !board.projects.items.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if board.isConfigured && hasFetchedAnything {
                searchField
                Divider()
            }
            ForEach(board.sourceFailures, id: \.self) { failure in
                BannerRowView(icon: "exclamationmark.triangle", text: failure)
            }
            if let failure = board.jira.lastLinkFailure {
                BannerRowView(
                    icon: "arrow.triangle.pull",
                    text: "Couldn't check for pull requests — \(failure)"
                )
            }
            ForEach(board.moveFailures, id: \.self) { failure in
                BannerRowView(
                    icon: "arrow.left.arrow.right",
                    text: failure,
                    actionTitle: "Dismiss",
                    action: { board.dismissMoveFailures() }
                )
            }
            if let request = board.jira.fieldRequest {
                JiraMoveFormView(
                    request: request,
                    onSubmit: { board.jira.submitFields($0) },
                    onCancel: { board.jira.cancelFields() }
                )
                .id("\(request.key) \(request.to.name)")
                Divider()
            }
            content
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter by key, number or title", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)
                .onSubmit { isSearchFocused = false }
            if isSearching {
                Button {
                    board.searchQuery = ""
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

    @ViewBuilder
    private var content: some View {
        if !board.isConfigured {
            PaneMessageView(
                icon: "square.stack.3d.up",
                title: "The board isn't set up yet",
                detail: "Sign in to Jira, or switch on a GitHub project, to see the work assigned to you.",
                actionTitle: "Settings…",
                action: onOpenSettings
            )
        } else {
            switch board.paneState {
            case .loading:
                PaneMessageView(icon: "square.stack.3d.up", title: "Loading…")
            case .failed:
                PaneMessageView(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't load the board",
                    detail: board.failureLines.joined(separator: "\n"),
                    actionTitle: "Settings…",
                    action: onOpenSettings
                )
            case .empty:
                PaneMessageView(
                    icon: "checkmark.circle",
                    title: "Nothing assigned to you",
                    detail: "Nothing on Jira or your GitHub projects is assigned to you and still open."
                )
            case .emptyByFilter where isSearching:
                PaneMessageView(
                    icon: "magnifyingglass",
                    title: "No card matches",
                    detail: "Nothing assigned to you matches “\(board.searchQuery)”.",
                    actionTitle: "Clear the filter",
                    action: { board.searchQuery = "" }
                )
            case .emptyByFilter:
                PaneMessageView(
                    icon: "checkmark.circle",
                    title: "Nothing to show",
                    detail: "Everything assigned to you is parked, hidden, or finished "
                        + "outside the window on the Board settings tab."
                )
            case .content, .stale:
                if board.showsBoard { boardView } else { rows }
            }
        }
    }

    private struct Section {
        let lane: BoardLane
        let cap: Int
        let height: CGFloat
    }

    /// Stacked in the order you act on them, not the order the work moves.
    private static let sections = [
        Section(lane: .inProgress, cap: 5, height: 260),
        Section(lane: .reviewing, cap: 4, height: 180),
        Section(lane: .testing, cap: 4, height: 180),
        Section(lane: .toDo, cap: 5, height: 220),
        Section(lane: .done, cap: 4, height: 180),
    ]

    private var boardView: some View {
        BoardView(
            columns: board.columns,
            board: board,
            filter: filter,
            onOpenCard: onOpenCard,
            cardLink: cardLink,
            cardJira: jiraReference,
            onOpenLink: onOpenLink
        )
    }

    /// Only a pair: a Jira card's own Copy ID and link are already Jira's.
    private func jiraReference(_ card: BoardCard) -> JiraKeyReference? {
        guard case .paired(let key, _) = card.id else { return nil }
        return JiraKeyReference(key: key, link: jiraKeyLink(key), open: onOpenJiraLink)
    }

    private var rows: some View {
        let columns = board.columns
        let shown = Self.sections.compactMap { section in
            columns.first { $0.lane == section.lane && !$0.cards.isEmpty }.map { (section, $0) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.1.id) { index, pair in
                if index > 0 { Divider() }
                self.section(pair.0, pair.1)
            }
        }
    }

    /// Its own scroll per section, capped like the pull request sections, so a
    /// long list of one kind cannot push the others off the popover.
    @ViewBuilder
    private func section(_ section: Section, _ column: BoardColumn) -> some View {
        PaneHeaderView(title: column.title, trailing: "\(column.cards.count)")
        if column.cards.count > section.cap {
            ScrollView { cardRows(column) }
                .frame(height: section.height)
        } else {
            cardRows(column)
        }
    }

    private func cardRows(_ column: BoardColumn) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(column.cards) { card in
                BoardRowView(
                    card: card,
                    links: filter.apply(to: card.links),
                    isExpanded: board.isExpanded(card.id),
                    showsPriority: column.showsPriority,
                    isMoving: board.isMoving(card.id),
                    onToggle: { board.toggle(card.id) },
                    onOpen: { onOpenCard(card) },
                    onOpenLink: onOpenLink
                )
                .boardCardMenu(card, board: board, link: cardLink(card), jira: jiraReference(card))
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}
