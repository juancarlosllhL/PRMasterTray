import SwiftUI
import PRMasterCore

/// What the popover's latest poll says about the pull request in the window.
struct DiffLiveState: Equatable {
    let head: String?
    let isReady: Bool
    /// Why Merge is unavailable, in the row's own words.
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

    var actionTitle: String {
        switch self {
        case .mine: return "Merge"
        case .team: return "Approve"
        }
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

    var body: some View {
        let palette = paletteInputs.resolved(monochromeEnabled: appearance.monochromeEnabled)
        let liveState = live()

        HSplitView {
            sidebar(palette)
                .frame(minWidth: 220, idealWidth: 290, maxWidth: 440)
            VStack(spacing: 0) {
                header
                Divider()
                if let banner = DiffBanner.banner(for: store.phase, isTruncated: store.diff?.isTruncated ?? false) {
                    bannerView(banner, palette)
                }
                diffBody(palette)
                Divider()
                bottomBar(liveState)
            }
            .frame(minWidth: 480)
        }
        .frame(minWidth: 760, minHeight: 420)
        .environment(\.palette, palette)
        .task {
            await store.load()
            selectedFile = initialFile
        }
        .onChange(of: liveState, initial: true) { _, state in
            store.observe(liveHead: state.head, isReady: state.isReady)
        }
        .onChange(of: selectedFile) { _, path in
            guard let path else { return }
            if store.collapsed.contains(path) { store.toggleCollapsed(path) }
            scrollTarget = path
        }
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
        let shown = DiffSearch.filter(files, by: fileFilter)
        return List(selection: $selectedFile) {
            Section {
                if shown.isEmpty && !files.isEmpty {
                    Text("No files match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { file in
                    DiffFileRow(
                        file: file,
                        highlights: DiffSearch.pathHighlights(of: fileFilter, in: file.path),
                        canMarkViewed: store.canMarkViewed,
                        failure: store.viewedFailures[file.path],
                        onViewed: { viewed in Task { await store.setViewed(file.path, viewed) } }
                    )
                    .tag(file.path)
                }
            } header: {
                Text(verbatim: "\(files.filter { $0.viewed == .viewed }.count) of \(files.count) viewed")
            }
        }
        .listStyle(.sidebar)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(verbatim: summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Layout", selection: $store.layout) {
                Text("Unified").tag(DiffLayout.unified)
                Text("Split").tag(DiffLayout.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        let noun = files.count == 1 ? "file" : "files"
        return "\(files.count) \(noun) changed · +\(additions) −\(deletions)"
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
                scrollTarget: $scrollTarget, onToggleFile: store.toggleCollapsed
            )
        }
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
            Button(subject.actionTitle) {
                if let target = store.mergeTarget { onAct(target) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.mergeTarget == nil)
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
