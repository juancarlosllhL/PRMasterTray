import Foundation

/// Fallback is `open`, never `merged`: an unrecognised state must not tell the
/// user work has shipped when it has not.
public enum LinkedPullRequestState: String, Sendable, Equatable, CaseIterable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"

    public var label: String {
        switch self {
        case .open:   return "open"
        case .merged: return "merged"
        case .closed: return "closed"
        }
    }

    public var tint: ReadinessTint {
        switch self {
        case .open:   return .blue
        case .merged: return .green
        case .closed: return .gray
        }
    }
}

/// A pull request found by searching for a Jira issue key.
public struct LinkedPullRequest: Sendable, Equatable, Identifiable, FilterableRepository {
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let repo: String
    public let isPrivate: Bool
    public let isDraft: Bool
    public let state: LinkedPullRequestState

    public var organization: String { String(repo.prefix { $0 != "/" }) }

    public init(
        id: String,
        number: Int,
        title: String,
        url: URL,
        repo: String,
        isPrivate: Bool,
        isDraft: Bool,
        state: LinkedPullRequestState
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repo = repo
        self.isPrivate = isPrivate
        self.isDraft = isDraft
        self.state = state
    }
}
