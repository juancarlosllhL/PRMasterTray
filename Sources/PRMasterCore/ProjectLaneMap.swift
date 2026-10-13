import Foundation

/// Which GitHub projects the board shows, by node id. An allowlist, unlike
/// `TeamFilter`: an organization has many boards and only yours belong here.
public struct ProjectSelection: Sendable, Equatable, Codable {
    public var enabled: Set<String>

    public init(enabled: Set<String> = []) {
        self.enabled = enabled
    }

    public var isEmpty: Bool { enabled.isEmpty }

    public func shows(_ project: GitHubProject) -> Bool {
        enabled.contains(project.id)
    }

    public mutating func set(_ project: GitHubProject, shown: Bool) {
        if shown {
            enabled.insert(project.id)
        } else {
            enabled.remove(project.id)
        }
    }
}

/// Raw values are persisted, so renaming a case resets every override.
public enum LaneChoice: String, Sendable, Codable, CaseIterable {
    case hidden, toDo, inProgress, reviewing, testing, done

    public init(lane: BoardLane?) {
        switch lane {
        case nil:          self = .hidden
        case .toDo:        self = .toDo
        case .inProgress:  self = .inProgress
        case .reviewing:   self = .reviewing
        case .testing:     self = .testing
        case .done:        self = .done
        }
    }

    public var lane: BoardLane? {
        switch self {
        case .hidden:     return nil
        case .toDo:       return .toDo
        case .inProgress: return .inProgress
        case .reviewing:  return .reviewing
        case .testing:    return .testing
        case .done:       return .done
        }
    }

    public var label: String { lane?.title ?? "Hidden" }
}

/// Where each project's Status options land on the board. Only the user's own
/// choices are stored; everything else is guessed from the option's name.
/// Keyed by option id, so renaming a column on GitHub keeps its choice.
public struct ProjectLaneMap: Sendable, Equatable, Codable {
    /// Stands in for an option id on items with no Status at all, which are
    /// not yet triaged and so start hidden.
    public static let noStatus = ""

    /// Project id, then option id.
    public var overrides: [String: [String: LaneChoice]]

    public init(overrides: [String: [String: LaneChoice]] = [:]) {
        self.overrides = overrides
    }

    public func choice(optionID: String?, name: String?, in project: String) -> LaneChoice {
        if let chosen = overrides[project]?[optionID ?? Self.noStatus] { return chosen }
        guard optionID != nil else { return .hidden }
        return LaneChoice(lane: BoardLane.guess(optionName: name ?? ""))
    }

    public func lane(optionID: String?, name: String?, in project: String) -> BoardLane? {
        choice(optionID: optionID, name: name, in: project).lane
    }

    public mutating func set(_ choice: LaneChoice, optionID: String, in project: String) {
        overrides[project, default: [:]][optionID] = choice
    }

    /// The option a move into `lane` sets: the one named like the column, or
    /// else the first that lands there in board order.
    public func target(for lane: BoardLane, in project: GitHubProject) -> StatusOption? {
        let landing = project.options.filter {
            self.lane(optionID: $0.id, name: $0.name, in: project.id) == lane
        }
        return landing.first { $0.name.caseInsensitiveCompare(lane.title) == .orderedSame }
            ?? landing.first
    }
}
