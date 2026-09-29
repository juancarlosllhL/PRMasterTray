import SwiftUI
import PRMasterCore

/// What the popover's latest poll says about the pull request in the window.
struct DiffLiveState: Equatable {
    let head: String?
    let isReady: Bool
    /// Why Approve is unavailable.
    let blocker: String?
}

enum DiffSubject {
    case mine(PullRequest)
    case team(ReviewRequest)

    var id: String {
        switch self {
        case .mine(let pr): return pr.id
        case .team(let request): return request.id
        }
    }

    var repo: String {
        switch self {
        case .mine(let pr): return pr.repo
        case .team(let request): return request.repo
        }
    }

    var number: Int {
        switch self {
        case .mine(let pr): return pr.number
        case .team(let request): return request.number
        }
    }

    var title: String {
        switch self {
        case .mine(let pr): return pr.displayTitle
        case .team(let request): return request.displayTitle
        }
    }

    var url: URL {
        switch self {
        case .mine(let pr): return pr.url
        case .team(let request): return request.url
        }
    }

    /// Only someone else's pull request can be approved; your own is merged from its row.
    var canBeApproved: Bool {
        if case .team = self { return true }
        return false
    }
}

struct DiffWindowView: View {
    @Bindable var store: DiffStore
    let subject: DiffSubject
    let live: () -> DiffLiveState
    let appearance: AppearanceStore
    let onAct: (MergeTarget) -> Void
    let onOpenOnGitHub: () -> Void
    var initialFile: String?

    var paletteInputs = PaletteInputs()
    @State private var scrollTarget: String?
    @State private var selectedFile: String?
    @State private var fileFilter = Debug.fileFilter ?? ""
    @State private var expandedSections: Set<FileSection> = []
    @AppStorage("diffDescriptionShown") private var showsDescription = true
    @FocusState private var findFocused: Bool

    var body: some View {
        let palette = paletteInputs.resolved(monochromeEnabled: appearance.monochromeEnabled)
        let liveState = live()

        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar(palette)
                    .frame(minWidth: 240, maxWidth: 440)
                VStack(spacing: 0) {
                    if let banner = DiffBanner.banner(for: store.phase, isTruncated: store.diff?.isTruncated ?? false) {
                        bannerView(banner, palette)
                    }
                    diffBody(palette)
                    if store.isFinding {
                        Divider()
                        findBar
                    }
                    Divider()
                    bottomBar(liveState)
                }
                .frame(minWidth: 480, maxWidth: .infinity)
                .layoutPriority(1)
                if showsDescription {
                    DescriptionPanel(
                        html: store.diff?.descriptionHTML, baseURL: subject.url, isLoading: store.phase == .loading
                    )
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 560)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 420)
        .environment(\.palette, palette)
        .task {
            await store.load()
            selectedFile = initialFile
            if let query = Debug.findQuery { Debug.typeFind(query) }
        }
        .onChange(of: liveState, initial: true) { _, state in
            store.observe(liveHead: state.head, isReady: state.isReady)
        }
        .onChange(of: store.isFinding) { _, finding in
            if finding { findFocused = true }
        }
        .onChange(of: SyntaxTheme(appearance: palette.appearance, contrast: palette.contrast), initial: true) { _, theme in
            store.setTheme(theme)
        }
        .onChange(of: scopeInputs, initial: true) { _, inputs in
            store.setScope(FileScope(patterns: inputs.patterns, gitAttributes: inputs.gitAttributes))
        }
        .onChange(of: selectedFile) { _, path in
            guard let path else { return }
            store.prioritise(path)
            if store.isCollapsed(path) { store.toggleCollapsed(path) }
            expandedSections.insert(store.scope.section(of: path))
            scrollTarget = path
        }
    }

    /// Compared rather than the scope itself, so a re-render does not recompile every pattern.
    private struct ScopeInputs: Equatable {
        let patterns: [FileSection: [String]]
        let gitAttributes: String?
    }

    private var scopeInputs: ScopeInputs {
        ScopeInputs(
            patterns: appearance.scopePatterns,
            gitAttributes: appearance.honoursGitAttributes ? store.diff?.gitAttributes : nil
        )
    }

    private var files: [DiffFile] { store.diff?.files ?? [] }

    private func sidebar(_ palette: ResolvedPalette) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter files", text: $fileFilter)
                    .textFieldStyle(.plain)
                if !fileFilter.isEmpty {
                    Button { fileFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear filter")
                        .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            fileList(palette)
        }
    }

    private func fileList(_ palette: ResolvedPalette) -> some View {
        let review = store.reviewFiles
        let shown = DiffSearch.filter(review, by: fileFilter)
        let setAside = store.groups.filter { $0.section != .review }
        return List(selection: $selectedFile) {
            Section {
                if review.isEmpty && !files.isEmpty {
                    Text("Every changed file is set aside.")
                        .foregroundStyle(.secondary)
                } else if DiffSearch.filter(files, by: fileFilter).isEmpty && !files.isEmpty {
                    Text("No files match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown, content: fileRow)
            } header: {
                Text(verbatim: "\(store.viewedReviewCount) of \(review.count) viewed")
            }
            ForEach(setAside, id: \.section) { group in
                let matching = DiffSearch.filter(group.files, by: fileFilter)
                if !matching.isEmpty {
                    Section(isExpanded: isExpanded(group.section)) {
                        ForEach(matching, content: fileRow)
                    } header: {
                        Text(verbatim: group.section.heading(count: group.files.count))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func fileRow(_ file: DiffFile) -> some View {
        DiffFileRow(
            file: file,
            highlights: DiffSearch.pathHighlights(of: fileFilter, in: file.path),
            canMarkViewed: store.canMarkViewed,
            failure: store.viewedFailures[file.path],
            onViewed: { viewed in Task { await store.setViewed(file.path, viewed) } }
        )
        .tag(file.path)
    }

    /// Closed until opened, except while a filter is typed: a match must never be hidden.
    private func isExpanded(_ section: FileSection) -> Binding<Bool> {
        Binding(
            get: { !fileFilter.trimmingCharacters(in: .whitespaces).isEmpty || expandedSections.contains(section) },
            set: { expanded in
                if expanded { expandedSections.insert(section) } else { expandedSections.remove(section) }
            }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(verbatim: summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Layout", selection: $store.layout) {
                Label("Unified", systemImage: "rectangle")
                    .labelStyle(.iconOnly)
                    .help("Unified")
                    .tag(DiffLayout.unified)
                Label("Split", systemImage: "rectangle.split.2x1")
                    .labelStyle(.iconOnly)
                    .help("Split")
                    .tag(DiffLayout.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { showsDescription.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.accessoryBar)
            .help(showsDescription ? "Hide description" : "Show description")
            .accessibilityLabel(showsDescription ? "Hide description" : "Show description")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let review = store.reviewFiles
        let additions = review.reduce(0) { $0 + $1.additions }
        let deletions = review.reduce(0) { $0 + $1.deletions }
        let noun = review.count == 1 ? "file" : "files"
        let setAside = store.setAsideCount > 0 ? " · \(store.setAsideCount) set aside" : ""
        return "\(review.count) \(noun) changed · +\(additions) −\(deletions)\(setAside)"
    }

    @ViewBuilder
    private func diffBody(_ palette: ResolvedPalette) -> some View {
        if store.phase == .loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.diff == nil {
            Color.clear
        } else if store.rows.isEmpty {
            Text("No files changed.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffTableView(
                rows: store.rows, layout: store.layout, palette: palette,
                fontFamily: appearance.diffFontFamily,
                fontSize: appearance.diffFontSize,
                ligatures: appearance.diffLigatures,
                matches: store.findMatches, currentMatch: store.currentFindMatch,
                scrollTarget: $scrollTarget, onToggleFile: store.toggleCollapsed,
                onTopFile: store.prioritise
            )
        }
    }

    private func closeFind() { store.closeFind() }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find in diff", text: $store.findQuery)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .frame(maxWidth: 320)
                .onKeyPress(.return, phases: .down) { press in
                    press.modifiers.contains(.shift) ? store.findPrevious() : store.findNext()
                    return .handled
                }
                .onExitCommand(perform: closeFind)
            Text(verbatim: findCount)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            Button(action: store.findPrevious) { Image(systemName: "chevron.up") }
                .help("Previous match (Shift-Return)")
                .accessibilityLabel("Previous match")
                .disabled(store.findMatches.isEmpty)
            Button(action: store.findNext) { Image(systemName: "chevron.down") }
                .help("Next match (Return)")
                .accessibilityLabel("Next match")
                .disabled(store.findMatches.isEmpty)
            Spacer()
            Button("Done", action: closeFind)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var findCount: String {
        guard !store.findQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        guard let index = store.currentFindIndex else { return "No matches" }
        return "\(index + 1) of \(store.findMatches.count)"
    }

    private func bannerView(_ banner: DiffBanner, _ palette: ResolvedPalette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.color(.orange))
                .accessibilityHidden(true)
            Text(verbatim: banner.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            ForEach(banner.actions, id: \.self) { action in
                switch action {
                case .reload: Button("Reload") { Task { await store.load() } }
                case .retry: Button("Retry") { Task { await store.load() } }
                case .openOnGitHub: Button("Open on GitHub", action: onOpenOnGitHub)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.wash(.orange))
    }

    private func bottomBar(_ liveState: DiffLiveState) -> some View {
        HStack(spacing: 10) {
            if store.phase == .loaded, let blocker = liveState.blocker {
                Text(verbatim: blocker)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open on GitHub", action: onOpenOnGitHub)
            if subject.canBeApproved {
                Button("Approve") {
                    if let target = store.mergeTarget { onAct(target) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.mergeTarget == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct DiffFileRow: View {
    let file: DiffFile
    let highlights: (directory: [Range<Int>], name: [Range<Int>])
    let canMarkViewed: Bool
    let failure: String?
    let onViewed: (Bool) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityLabel(file.change.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchHighlight.text((file.path as NSString).lastPathComponent, highlights.name))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(SearchHighlight.text(directory, highlights.directory))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if file.viewed == .dismissed {
                    Text("Changed since viewed")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.color(.orange))
                }
                if let failure {
                    Text(verbatim: failure)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.color(.red))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Text(verbatim: "+\(file.additions)").foregroundStyle(palette.color(.green))
                Text(verbatim: "−\(file.deletions)").foregroundStyle(palette.color(.red))
            }
            .font(.system(size: 10, design: .monospaced))
            if canMarkViewed {
                Toggle("Viewed", isOn: Binding(get: { file.viewed == .viewed }, set: { onViewed($0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Viewed")
            }
        }
        .help(file.previousPath.map { "Renamed from \($0)" } ?? file.path)
    }

    private var directory: String {
        let parent = (file.path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private var symbol: String {
        switch file.change {
        case .added, .copied: return "plus.square"
        case .removed: return "minus.square"
        case .renamed: return "arrow.right.square"
        case .modified, .changed, .unchanged: return "square.and.pencil"
        }
    }
}
