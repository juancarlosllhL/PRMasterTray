import Foundation
import Observation

public struct MergeTarget: Equatable, Sendable {
    public let id: String
    public let oid: String
}

/// State behind one diff window.
///
/// The live row from the popover's poll says whether the pull request is still
/// open and where its head is now; the diff never re-derives from it.
@MainActor
@Observable
public final class DiffStore {

    public enum Phase: Equatable, Sendable {
        case loading, loaded, failed(String), headMoved, closed
    }

    public private(set) var phase: Phase = .loading
    public private(set) var diff: PullRequestDiff?
    public private(set) var rows: [DiffRow] = []
    public private(set) var collapsed: Set<String> = []
    /// GitHub's message for the last viewed toggle it refused, by path.
    public private(set) var viewedFailures: [String: String] = [:]

    public var layout: DiffLayout {
        didSet {
            guard layout != oldValue else { return }
            preferences.setDiffLayout(layout)
            rebuildRows()
        }
    }

    public var canMarkViewed: Bool { viewedWriter != nil }

    /// Nil unless what was read is still what GitHub would act on.
    public var mergeTarget: MergeTarget? {
        guard phase == .loaded, isReady, let diff, !diff.isTruncated else { return nil }
        return MergeTarget(id: diff.pullRequestID, oid: diff.headOid)
    }

    private let repo: String
    private let number: Int
    private let source: PullRequestDiffing?
    private let viewedWriter: PullRequestDiffing?
    private let preferences: PreferenceStoring
    private var liveHead: String??
    private var isReady = false

    public init(
        repo: String, number: Int, source: PullRequestDiffing?, viewedWriter: PullRequestDiffing?,
        preferences: PreferenceStoring = UserDefaultsPreferences()
    ) {
        self.repo = repo
        self.number = number
        self.source = source
        self.viewedWriter = viewedWriter
        self.preferences = preferences
        self.layout = preferences.diffLayout()
    }

    public func load() async {
        guard let source else {
            phase = .failed("Diffs aren't loaded while the app is showing debug data.")
            return
        }
        phase = .loading
        do {
            var loaded = try await source.loadDiff(repo: repo, number: number)
            let files = loaded.files
            // About 200ms for 50,000 lines in release, so it stays off the main actor.
            loaded.files = await Task.detached { files.map(Tokenizer.highlighted) }.value
            diff = loaded
            collapsed = Set(loaded.files.filter { $0.viewed == .viewed }.map(\.path))
            viewedFailures = [:]
            rebuildRows()
            phase = .loaded
            evaluateLiveState()
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Called with the popover's latest row: its head, or nil once it is gone.
    public func observe(liveHead: String?, isReady: Bool) {
        self.liveHead = .some(liveHead)
        self.isReady = isReady
        evaluateLiveState()
    }

    public func setViewed(_ path: String, _ viewed: Bool) async {
        guard let viewedWriter, let diff, let index = diff.files.firstIndex(where: { $0.path == path })
        else { return }
        let previous = diff.files[index].viewed
        apply(viewed ? .viewed : .unviewed, to: path)
        viewedFailures[path] = nil
        do {
            try await viewedWriter.setViewed(pullRequestID: diff.pullRequestID, path: path, viewed: viewed)
        } catch {
            apply(previous, to: path)
            viewedFailures[path] = Self.message(for: error)
        }
    }

    public func toggleCollapsed(_ path: String) {
        if collapsed.remove(path) == nil { collapsed.insert(path) }
        rebuildRows()
    }

    private func apply(_ state: ViewedState, to path: String) {
        guard let index = diff?.files.firstIndex(where: { $0.path == path }) else { return }
        diff?.files[index].viewed = state
        if state == .viewed { collapsed.insert(path) } else { collapsed.remove(path) }
        rebuildRows()
    }

    private func evaluateLiveState() {
        guard let diff, let liveHead, phase == .loaded || phase == .headMoved || phase == .closed else { return }
        switch liveHead {
        case nil: phase = .closed
        case diff.headOid: phase = .loaded
        default: phase = .headMoved
        }
    }

    private func rebuildRows() {
        rows = DiffRows.build(diff?.files ?? [], layout: layout, collapsed: collapsed)
    }

    private static func message(for error: Error) -> String {
        (error as? PRMasterError)?.errorDescription ?? error.localizedDescription
    }
}
