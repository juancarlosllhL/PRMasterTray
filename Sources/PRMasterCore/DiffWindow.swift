/// One window per key. Generic so the rule is testable without AppKit.
@MainActor
public final class WindowRegistry<Window: AnyObject> {
    private var windows: [String: Window] = [:]

    public init() {}

    public var count: Int { windows.count }

    public func window(for key: String, make: () -> Window) -> (window: Window, isNew: Bool) {
        if let existing = windows[key] { return (existing, false) }
        let created = make()
        windows[key] = created
        return (created, true)
    }

    public func remove(_ key: String) {
        windows[key] = nil
    }
}

/// What the diff window says when it cannot offer Merge or Approve.
public struct DiffBanner: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case reload, retry, openOnGitHub
    }

    public let message: String
    public let actions: [Action]

    public static func banner(for phase: DiffStore.Phase, isTruncated: Bool) -> DiffBanner? {
        switch phase {
        case .loading:
            return nil
        case .headMoved:
            return DiffBanner(
                message: "New commits were pushed after this diff loaded. Reload to review them before acting.",
                actions: [.reload]
            )
        case .closed:
            return DiffBanner(message: "This pull request is no longer open.", actions: [])
        case .failed(let message):
            return DiffBanner(message: message, actions: [.retry, .openOnGitHub])
        case .loaded where isTruncated:
            return DiffBanner(
                message: "GitHub lists only the first 3000 files, so this diff is incomplete. Review the rest on GitHub.",
                actions: [.openOnGitHub]
            )
        case .loaded:
            return nil
        }
    }
}
