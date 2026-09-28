import Foundation

public struct JiraGroups: Sendable, Equatable {
    public let toDo: [JiraIssue]
    public let inProgress: [JiraIssue]
    public let reviewing: [JiraIssue]
    public let testing: [JiraIssue]
    public let done: [JiraIssue]

    public var count: Int {
        toDo.count + inProgress.count + reviewing.count + testing.count + done.count
    }
    public var isEmpty: Bool { count == 0 }
}

public enum JiraGrouping {

    /// The To do category also holds parked work — On Hold, Awaiting Customer,
    /// Canceled — which is not waiting to be picked up.
    static let startableStatuses: Set<String> = ["new", "to do", "todo"]

    /// Priority, then the newest first, then the key so an exact tie cannot
    /// reshuffle the list on every poll.
    static func precedes(_ one: JiraIssue, _ other: JiraIssue) -> Bool {
        guard one.priority.order == other.priority.order else {
            return one.priority.order < other.priority.order
        }
        let created = one.createdAt ?? .distantPast
        let otherCreated = other.createdAt ?? .distantPast
        return created == otherCreated ? one.key < other.key : created > otherCreated
    }

    static func isStartable(_ statusName: String) -> Bool {
        startableStatuses.contains(
            statusName.trimmingCharacters(in: .whitespaces).lowercased()
        )
    }

    /// Whole words, or "Latest" and "Contested" would read as work in test.
    static func isTesting(_ statusName: String) -> Bool {
        hasWord(statusName, in: ["testing", "test"])
    }

    static func isReviewing(_ statusName: String) -> Bool {
        hasWord(statusName, in: ["reviewing", "review"])
    }

    private static func hasWord(_ statusName: String, in words: Set<String>) -> Bool {
        statusName.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { words.contains(String($0)) }
    }

    /// The one place a status is given a column, so grouping and choosing where
    /// a move lands cannot disagree. `nil` is parked work, shown nowhere.
    public static func lane(statusName: String, category: JiraStatusCategory) -> JiraLane? {
        switch category {
        case .toDo:                 return isStartable(statusName) ? .toDo : nil
        case .inProgress, .unknown:
            if isTesting(statusName) { return .testing }
            return isReviewing(statusName) ? .reviewing : .inProgress
        case .done:                 return .done
        }
    }

    public static func lane(for issue: JiraIssue) -> JiraLane? {
        lane(statusName: issue.statusName, category: issue.statusCategory)
    }

    /// Filtered against the window here as well as in the query, because a poll
    /// can be minutes old. An unknown category counts as in progress: it is
    /// still work in flight, and dropping it would hide the issue outright.
    /// `overrides` places a card being moved in its target lane before Jira confirms.
    public static func group(
        _ issues: [JiraIssue],
        window: JiraWindow,
        now: Date,
        overrides: [String: JiraLane] = [:]
    ) -> JiraGroups {
        var toDo: [JiraIssue] = []
        var inProgress: [JiraIssue] = []
        var reviewing: [JiraIssue] = []
        var testing: [JiraIssue] = []
        var done: [JiraIssue] = []

        for issue in issues {
            let moving = overrides[issue.key]
            switch moving ?? lane(for: issue) {
            case nil:
                continue
            case .toDo:
                toDo.append(issue)
            case .inProgress:
                inProgress.append(issue)
            case .reviewing:
                reviewing.append(issue)
            case .testing:
                testing.append(issue)
            case .done:
                let finishedAt = moving == nil ? issue.categoryChangedAt : now
                if window.includes(finishedAt: finishedAt, now: now) {
                    done.append(issue)
                }
            }
        }

        return JiraGroups(
            toDo: toDo.sorted(by: precedes),
            inProgress: inProgress.sorted(by: precedes),
            reviewing: reviewing.sorted(by: precedes),
            testing: testing.sorted(by: precedes),
            done: done.sorted {
                ($0.categoryChangedAt ?? .distantPast) > ($1.categoryChangedAt ?? .distantPast)
            }
        )
    }
}
