import Foundation

public struct JiraStatus: Sendable, Equatable {
    public let name: String
    public let category: JiraStatusCategory

    public init(name: String, category: JiraStatusCategory) {
        self.name = name
        self.category = category
    }

    public var lane: JiraLane? { JiraGrouping.lane(statusName: name, category: category) }
}

public struct JiraTransition: Sendable, Equatable {
    public let id: String
    public let to: JiraStatus
    /// Offered from every status: in ACME, parking an issue or cancelling it.
    public let isGlobal: Bool
    /// A field Jira insists on, which the app has no way to fill.
    public let needsInput: Bool
    /// The screen's fields the app can ask the user for before posting.
    public let fields: [JiraField]

    public init(
        id: String, to: JiraStatus, isGlobal: Bool, needsInput: Bool, fields: [JiraField] = []
    ) {
        self.id = id
        self.to = to
        self.isGlobal = isGlobal
        self.needsInput = needsInput
        self.fields = fields
    }
}

/// Picks one transition at a time, because the workflow itself is readable
/// only by Jira administrators. Only what the current status offers is known.
public enum JiraRoute {

    public static func nextHop(
        from current: JiraStatus,
        toward target: JiraLane,
        offered: [JiraTransition],
        visited: Set<String>
    ) -> JiraTransition? {
        guard let here = current.lane else { return nil }

        let usable = offered.compactMap { transition -> (JiraTransition, JiraLane)? in
            guard !transition.needsInput, !visited.contains(transition.to.name),
                  !transition.isGlobal || namesALane(transition.to),
                  let lane = transition.to.lane
            else { return nil }
            return (transition, lane)
        }

        let arriving = usable.filter { $0.1 == target }.map(\.0)
        if !arriving.isEmpty {
            return arriving.first { $0.to.name.caseInsensitiveCompare(target.title) == .orderedSame }
                ?? arriving.first { !$0.isGlobal }
                ?? arriving.first
        }

        func distance(_ lane: JiraLane) -> Int { abs(lane.rawValue - target.rawValue) }
        func rank(_ candidate: (JiraTransition, JiraLane)) -> (Int, Int) {
            (distance(candidate.1), candidate.0.isGlobal ? 1 : 0)
        }

        // Strict `<` keeps Jira's own order on a tie.
        var best: (JiraTransition, JiraLane)?
        for candidate in usable where distance(candidate.1) <= distance(here) {
            if best.map({ rank(candidate) < rank($0) }) ?? true { best = candidate }
        }
        return best?.0
    }

    /// Cancel is global and category done, and some sites ask no resolution for it.
    private static func namesALane(_ status: JiraStatus) -> Bool {
        JiraLane.allCases.contains { $0.title.caseInsensitiveCompare(status.name) == .orderedSame }
    }
}
