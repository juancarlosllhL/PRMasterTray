import Foundation

public struct JiraGroups: Sendable, Equatable {
    public let toDo: [JiraIssue]
    public let inProgress: [JiraIssue]
    public let testing: [JiraIssue]
    public let done: [JiraIssue]

    public var count: Int {
        toDo.count + inProgress.count + testing.count + done.count
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

    static func isStartable(_ issue: JiraIssue) -> Bool {
        startableStatuses.contains(
            issue.statusName.trimmingCharacters(in: .whitespaces).lowercased()
        )
    }

    /// Whole words, or "Latest" and "Contested" would read as work in test.
    static func isTesting(_ issue: JiraIssue) -> Bool {
        issue.statusName.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { $0 == "testing" || $0 == "test" }
    }

    /// Filtered against the window here as well as in the query, because a poll
    /// can be minutes old. An unknown category counts as in progress: it is
    /// still work in flight, and dropping it would hide the issue outright.
    public static func group(
        _ issues: [JiraIssue],
        window: JiraWindow,
        now: Date
    ) -> JiraGroups {
        var toDo: [JiraIssue] = []
        var inProgress: [JiraIssue] = []
        var testing: [JiraIssue] = []
        var done: [JiraIssue] = []

        for issue in issues {
            switch issue.statusCategory {
            case .toDo:
                if isStartable(issue) { toDo.append(issue) }
            case .inProgress, .unknown:
                if isTesting(issue) { testing.append(issue) } else { inProgress.append(issue) }
            case .done:
                if window.includes(finishedAt: issue.categoryChangedAt, now: now) {
                    done.append(issue)
                }
            }
        }

        return JiraGroups(
            toDo: toDo.sorted(by: precedes),
            inProgress: inProgress.sorted(by: precedes),
            testing: testing.sorted(by: precedes),
            done: done.sorted {
                ($0.categoryChangedAt ?? .distantPast) > ($1.categoryChangedAt ?? .distantPast)
            }
        )
    }
}
