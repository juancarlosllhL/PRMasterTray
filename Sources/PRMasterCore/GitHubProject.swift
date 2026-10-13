import Foundation

public struct StatusOption: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A GitHub Projects board. `Codable` because the list is persisted: a failed
/// discovery falls back to the last good list, the rule `knownTeams` follows.
public struct GitHubProject: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: String
    public let number: Int
    public let title: String
    public let owner: String
    public let url: URL
    /// Nil for a board with no single-select field named Status, which has no
    /// columns to map and nothing a move could set.
    public let statusFieldID: String?
    /// In board order, left to right.
    public let options: [StatusOption]

    public var hasStatus: Bool { statusFieldID != nil }

    public init(
        id: String, number: Int, title: String, owner: String, url: URL,
        statusFieldID: String?, options: [StatusOption]
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.owner = owner
        self.url = url
        self.statusFieldID = statusFieldID
        self.options = options
    }
}
