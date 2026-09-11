import Foundation
import Observation

public protocol JiraIssueFetching: Sendable {
    func fetchAssignedIssues(within window: JiraWindow) async throws -> [JiraIssue]
}

public protocol IssueLinkFetching: Sendable {
    func fetchPullRequests(forIssueKeys keys: [String]) async throws -> [String: [LinkedPullRequest]]
}

extension GitHubClient: IssueLinkFetching {}
extension JiraClient: JiraIssueFetching {}

/// All four look like an issue with nothing under it unless kept apart: still
/// being looked up, looked up and failed, looked up and genuinely none, found.
public enum IssueLinkState: Sendable, Equatable, CaseIterable {
    case loading
    case unknown
    case none
    case linked
}

@MainActor
@Observable
public final class JiraStore {

    public private(set) var issues: [JiraIssue] = []
    public private(set) var links: [String: [LinkedPullRequest]] = [:]
    public private(set) var lastSuccessfulFetch: Date?
    public private(set) var lastError: PRMasterError?
    /// Separate from `lastError` so a broken link lookup cannot raise the stale
    /// banner over a perfectly good issue list.
    public private(set) var lastLinkFailure: String?
    public private(set) var isRefreshing = false
    public private(set) var expandedKeys: Set<String> = []
    public private(set) var pendingLinkKeys: Set<String> = []

    /// Widening asks for issues the last search never requested, so this
    /// persists and then refetches rather than re-deriving what is in hand.
    public var window: JiraWindow {
        didSet {
            guard window != oldValue else { return }
            preferences.setJiraWindow(window)
            Task { await refresh() }
        }
    }

    /// Deliberately not persisted: a filter still in force on the next launch,
    /// with nothing on screen to say so, reads as a list that has broken.
    public var searchQuery = ""

    public var groups: JiraGroups {
        JiraGrouping.group(issues, window: window, now: now())
    }

    public var visibleGroups: JiraGroups { groups.matching(searchQuery) }

    private static let intervals: [Duration] = [.seconds(60), .seconds(120), .seconds(300)]

    /// `nil` until the user signs in, which is not a failure.
    private var issueClient: JiraIssueFetching?
    private let linkClient: IssueLinkFetching?
    private let preferences: PreferenceStoring
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?

    public var isConfigured: Bool { issueClient != nil }

    public init(
        issues issueClient: JiraIssueFetching?,
        links linkClient: IssueLinkFetching?,
        preferences: PreferenceStoring = UserDefaultsPreferences(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.issueClient = issueClient
        self.linkClient = linkClient
        self.preferences = preferences
        self.now = now
        self.sleep = sleep
        self.window = preferences.jiraWindow()
    }

    var currentInterval: Duration {
        Self.intervals[min(consecutiveFailures, Self.intervals.count - 1)]
    }

    // MARK: - Reading

    public func linkState(for key: String) -> IssueLinkState {
        if pendingLinkKeys.contains(key) { return .loading }
        guard let found = links[key] else { return .unknown }
        return found.isEmpty ? .none : .linked
    }

    public func links(for key: String, under filter: PRFilter) -> [LinkedPullRequest] {
        filter.apply(to: links[key] ?? [])
    }

    public func toggle(_ key: String) {
        if expandedKeys.contains(key) {
            expandedKeys.remove(key)
        } else {
            expandedKeys.insert(key)
        }
    }

    // MARK: - Refresh

    public func refresh() async {
        guard !isRefreshing else { return }
        guard let issueClient else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let fetched: [JiraIssue]
        do {
            fetched = try await issueClient.fetchAssignedIssues(within: window)
        } catch {
            consecutiveFailures += 1
            lastError = Self.asDomainError(error)
            return
        }

        let listed = fetched.filter { !$0.isEpic }
        issues = listed
        lastError = nil
        lastSuccessfulFetch = now()
        consecutiveFailures = 0

        await refreshLinks(for: listed)
    }

    /// Chunked so a long assigned list cannot build a document GitHub refuses.
    private func refreshLinks(for issues: [JiraIssue]) async {
        guard let linkClient, !issues.isEmpty else { return }

        let keys = issues.map(\.key)
        var collected: [String: [LinkedPullRequest]] = [:]
        var failure: PRMasterError?

        pendingLinkKeys = Set(keys.filter { links[$0] == nil })
        defer { pendingLinkKeys = [] }

        for chunk in Self.chunks(of: keys, size: Queries.issueKeyAliasCap) {
            do {
                let answer = try await linkClient.fetchPullRequests(forIssueKeys: chunk)
                collected.merge(answer) { existing, _ in existing }
            } catch {
                failure = Self.asDomainError(error)
            }
            // Resolved either way: a failed chunk reads as unknown, not loading.
            pendingLinkKeys.subtract(chunk)
        }

        // Only keys that answered are replaced, so a failed chunk leaves its
        // issues reading as unknown rather than as having none.
        links = links.filter { keys.contains($0.key) }.merging(collected) { _, new in new }
        lastLinkFailure = failure?.localizedDescription
    }

    static func chunks(of keys: [String], size: Int) -> [[String]] {
        guard size > 0 else { return [keys] }
        return stride(from: 0, to: keys.count, by: size).map {
            Array(keys[$0..<min($0 + size, keys.count)])
        }
    }

    private static func asDomainError(_ error: any Error) -> PRMasterError {
        error as? PRMasterError ?? .decoding(String(describing: error))
    }

    // MARK: - Polling

    func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await sleep(currentInterval)
            } catch {
                return
            }
        }
    }

    var isPolling: Bool { pollTask != nil }

    public func start() {
        guard pollTask == nil, isConfigured else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Signing in and out, which the app used to read only at launch.
    public func connect(_ client: JiraIssueFetching?) {
        stop()
        issueClient = client
        lastError = nil
        lastLinkFailure = nil
        consecutiveFailures = 0

        guard client != nil else {
            issues = []
            links = [:]
            pendingLinkKeys = []
            expandedKeys = []
            lastSuccessfulFetch = nil
            return
        }
        start()
    }
}
