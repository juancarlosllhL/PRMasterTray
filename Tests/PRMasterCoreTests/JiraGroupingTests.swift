import Foundation
import Testing
@testable import PRMasterCore

private let now = Date(timeIntervalSince1970: 1_000_000)

private func issue(
    _ key: String,
    category: JiraStatusCategory = .toDo,
    priority: JiraPriority = .medium,
    doneDaysAgo: Double? = nil,
    status: String = "To Do"
) -> JiraIssue {
    JiraIssue(
        key: key,
        summary: "summary",
        statusName: status,
        statusCategory: category,
        issueType: "Task",
        priority: priority,
        updatedAt: now,
        categoryChangedAt: doneDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
    )
}

@Suite("JiraPriority")
struct JiraPriorityTests {

    @Test("the priority set is exhaustive")
    func exhaustive() {
        #expect(JiraPriority.allCases.count == 6)
    }

    /// Ids verified live on this site. Sorting is by id ascending, which puts
    /// Critical first and, crucially, None last rather than first.
    @Test("ids match the site and order most important first", arguments: [
        (JiraPriority.critical, 1, "Critical"),
        (JiraPriority.high, 2, "High"),
        (JiraPriority.medium, 3, "Medium"),
        (JiraPriority.low, 4, "Low"),
        (JiraPriority.lowest, 5, "Lowest"),
        (JiraPriority.unset, 10_000, "None"),
    ])
    func idsMatchTheSite(priority: JiraPriority, id: Int, name: String) {
        #expect(priority.order == id)
        #expect(priority.name == name)
        #expect(JiraPriority(id: String(id)) == priority)
    }

    @Test("None sorts last, never first")
    func noneSortsLast() {
        let sorted = JiraPriority.allCases.sorted { $0.order < $1.order }
        #expect(sorted.first == .critical)
        #expect(sorted.last == .unset)
    }

    /// A priority this site does not define must not be read as Critical, which
    /// would float an unknown issue to the top of the list you pick work from.
    @Test("an unrecognised id is not critical", arguments: ["0", "99", "", "abc"])
    func unknownIsNotCritical(raw: String) {
        let resolved = JiraPriority(id: raw) ?? .unset
        #expect(resolved != .critical)
        #expect(resolved == .unset)
    }
}

@Suite("JiraWindow")
struct JiraWindowTests {

    @Test("the window set is exhaustive")
    func exhaustive() {
        #expect(JiraWindow.allCases.count == 4)
    }

    @Test("two weeks is the default")
    func defaultIsTwoWeeks() {
        #expect(JiraWindow.default == .twoWeeks)
        #expect(JiraWindow.twoWeeks.days == 14)
    }

    @Test("off has no duration and no qualifier")
    func offIsOff() {
        #expect(JiraWindow.off.days == nil)
        #expect(JiraWindow.off.doneQualifier == nil)
    }

    /// The JQL field is statusCategoryChangedDate rather than resolutiondate:
    /// an issue can reach Done carrying no resolution date, and one such issue
    /// was measured inside the 30 day window on this account.
    @Test("the qualifier asks about the category change, not the resolution",
          arguments: [JiraWindow.oneWeek, .twoWeeks, .oneMonth])
    func qualifierUsesCategoryChange(window: JiraWindow) throws {
        let qualifier = try #require(window.doneQualifier)
        #expect(qualifier.contains("statusCategoryChangedDate"))
        #expect(!qualifier.contains("resolutiondate"))
        #expect(qualifier.contains("-\(window.days!)d"))
    }

    @Test("raw values are stable", arguments: [
        (JiraWindow.off, "off"), (.oneWeek, "oneWeek"),
        (.twoWeeks, "twoWeeks"), (.oneMonth, "oneMonth"),
    ])
    func rawValuesStable(window: JiraWindow, raw: String) {
        #expect(window.rawValue == raw)
        #expect(JiraWindow(rawValue: raw) == window)
    }

    @Test("includes only what finished inside the window")
    func includesInsideOnly() {
        #expect(JiraWindow.twoWeeks.includes(finishedAt: now.addingTimeInterval(-1 * 86_400), now: now))
        #expect(JiraWindow.twoWeeks.includes(finishedAt: now.addingTimeInterval(-13 * 86_400), now: now))
        #expect(!JiraWindow.twoWeeks.includes(finishedAt: now.addingTimeInterval(-15 * 86_400), now: now))
        #expect(!JiraWindow.off.includes(finishedAt: now, now: now))
    }

    /// An issue with no timestamp cannot be shown to have finished recently.
    @Test("a missing finish time is not inside the window")
    func missingFinishIsOutside() {
        #expect(!JiraWindow.twoWeeks.includes(finishedAt: nil, now: now))
    }
}

@Suite("JiraGrouping")
struct JiraGroupingTests {

    @Test("issues split by category")
    func splitsByCategory() {
        let groups = JiraGrouping.group(
            [
                issue("A-1", category: .toDo),
                issue("A-2", category: .inProgress),
                issue("A-3", category: .done, doneDaysAgo: 1),
            ],
            window: .twoWeeks, now: now
        )

        #expect(groups.toDo.map(\.key) == ["A-1"])
        #expect(groups.inProgress.map(\.key) == ["A-2"])
        #expect(groups.done.map(\.key) == ["A-3"])
    }

    /// The list you pick your next task from, so priority decides the order.
    @Test("to do is ordered by priority, most important first")
    func toDoOrderedByPriority() {
        let groups = JiraGrouping.group(
            [
                issue("A-1", priority: .low),
                issue("A-2", priority: .critical),
                issue("A-3", priority: .unset),
                issue("A-4", priority: .high),
            ],
            window: .twoWeeks, now: now
        )

        #expect(groups.toDo.map(\.key) == ["A-2", "A-4", "A-1", "A-3"])
    }

    /// Equal priorities need a stable tie-break, or the list reshuffles itself
    /// on every poll for no reason.
    @Test("equal priorities fall back to the key")
    func equalPrioritiesTieBreakOnKey() {
        let groups = JiraGrouping.group(
            [
                issue("A-3", priority: .high),
                issue("A-1", priority: .high),
                issue("A-2", priority: .high),
            ],
            window: .twoWeeks, now: now
        )

        #expect(groups.toDo.map(\.key) == ["A-1", "A-2", "A-3"])
    }

    @Test("done is ordered by most recently finished")
    func doneOrderedByRecency() {
        let groups = JiraGrouping.group(
            [
                issue("A-1", category: .done, doneDaysAgo: 5),
                issue("A-2", category: .done, doneDaysAgo: 1),
                issue("A-3", category: .done, doneDaysAgo: 3),
            ],
            window: .twoWeeks, now: now
        )

        #expect(groups.done.map(\.key) == ["A-2", "A-3", "A-1"])
    }

    /// The query already filters by window, but a poll can be minutes old and
    /// an issue must not linger past its window because of it.
    @Test("done outside the window is dropped even if the server returned it")
    func doneOutsideWindowDropped() {
        let groups = JiraGrouping.group(
            [
                issue("A-1", category: .done, doneDaysAgo: 3),
                issue("A-2", category: .done, doneDaysAgo: 40),
            ],
            window: .twoWeeks, now: now
        )

        #expect(groups.done.map(\.key) == ["A-1"])
    }

    @Test("an off window shows no done issues at all")
    func offWindowHidesDone() {
        let groups = JiraGrouping.group(
            [
                issue("A-1", category: .done, doneDaysAgo: 1),
                issue("A-2", category: .toDo),
            ],
            window: .off, now: now
        )

        #expect(groups.done.isEmpty)
        #expect(groups.toDo.map(\.key) == ["A-2"])
    }

    /// A done issue carrying no timestamp cannot be placed in the window, and
    /// must not be shown rather than assumed recent.
    @Test("a done issue with no timestamp is dropped")
    func doneWithoutTimestampDropped() {
        let groups = JiraGrouping.group(
            [issue("A-1", category: .done, doneDaysAgo: nil)],
            window: .twoWeeks, now: now
        )

        #expect(groups.done.isEmpty)
    }

    /// An unknown category is still work in flight and must not vanish.
    @Test("an unknown category is kept with in progress")
    func unknownCategoryKept() {
        let groups = JiraGrouping.group(
            [issue("A-1", category: .unknown)], window: .twoWeeks, now: now
        )

        #expect(groups.inProgress.map(\.key) == ["A-1"])
    }

    @Test("nothing is lost or duplicated across the groups")
    func everyIssueLandsExactlyOnce() {
        let input = [
            issue("A-1", category: .toDo),
            issue("A-2", category: .inProgress),
            issue("A-3", category: .done, doneDaysAgo: 2),
            issue("A-4", category: .unknown),
        ]
        let groups = JiraGrouping.group(input, window: .twoWeeks, now: now)
        let landed = groups.toDo + groups.inProgress + groups.done

        #expect(Set(landed.map(\.key)) == Set(input.map(\.key)))
        #expect(landed.count == input.count)
    }

    @Test("an empty input yields three empty groups")
    func emptyInput() {
        let groups = JiraGrouping.group([], window: .twoWeeks, now: now)
        #expect(groups.toDo.isEmpty && groups.inProgress.isEmpty && groups.done.isEmpty)
        #expect(groups.isEmpty)
    }
}

/// The To do category also holds parked work — On Hold, Awaiting Customer,
/// Canceled — which is not waiting to be picked up and is left out entirely.
@Suite("JiraGrouping To do statuses")
struct JiraToDoStatusTests {

    private func grouped(_ status: String) -> [String] {
        JiraGrouping.group(
            [issue("ACME-1", category: .toDo, status: status)],
            window: .twoWeeks, now: now
        ).toDo.map(\.key)
    }

    @Test("only work not yet started is listed", arguments: [
        "New", "To Do", "new", "to do", "TODO", "  To Do  ",
    ])
    func startableIsListed(status: String) {
        #expect(grouped(status) == ["ACME-1"])
    }

    @Test("parked work is left out", arguments: [
        "On Hold", "Awaiting Customer", "Canceled", "Blocked", "Backlog",
    ])
    func parkedIsDropped(status: String) {
        #expect(grouped(status).isEmpty)
    }

    /// The rule is scoped to one section: a parked status filed under another
    /// category is still that category's business.
    @Test("a status elsewhere is untouched")
    func otherSectionsKeepTheirOwn() {
        let groups = JiraGrouping.group(
            [issue("ACME-1", category: .inProgress, status: "On Hold")],
            window: .twoWeeks, now: now
        )
        #expect(groups.inProgress.map(\.key) == ["ACME-1"])
    }

    @Test("what is listed and what is held apart are counted separately")
    func countsAreSeparate() {
        let groups = JiraGrouping.group(
            [
                issue("ACME-1", category: .toDo, status: "To Do"),
                issue("ACME-2", category: .toDo, status: "On Hold"),
                issue("ACME-3", category: .inProgress, status: "In Progress"),
            ],
            window: .twoWeeks, now: now
        )
        #expect(groups.count == 2)
        #expect(!groups.isEmpty)
    }
}

/// Work in test is finished as far as you are concerned and waiting on somebody
/// else, so it is listed apart from what you are still writing.
@Suite("JiraGrouping Testing")
struct JiraTestingStatusTests {

    private func grouped(_ status: String) -> JiraGroups {
        JiraGrouping.group(
            [issue("ACME-1", category: .inProgress, status: status)],
            window: .twoWeeks, now: now
        )
    }

    @Test("a status about testing gets its own list", arguments: [
        "Testing", "testing", "TESTING", "In Testing", "Ready for Testing", "  Testing  ",
    ])
    func testingIsSplitOut(status: String) {
        #expect(grouped(status).testing.map(\.key) == ["ACME-1"])
        #expect(grouped(status).inProgress.isEmpty)
    }

    /// Matched on whole words: "Latest" contains the letters and means nothing
    /// of the sort, and reviewing is somebody reading the code, not running it.
    @Test("everything else in flight stays in progress", arguments: [
        "In Progress", "Reviewing", "Code Review", "Latest", "Contested",
    ])
    func othersStayInProgress(status: String) {
        #expect(grouped(status).inProgress.map(\.key) == ["ACME-1"])
        #expect(grouped(status).testing.isEmpty)
    }

    /// The category is what places an issue; the name only splits what is
    /// already in flight.
    @Test("a testing name outside the in progress category is untouched")
    func categoryStillDecides() {
        let groups = JiraGrouping.group(
            [
                issue("ACME-1", category: .toDo, status: "Ready for Testing"),
                issue("ACME-2", category: .done, doneDaysAgo: 1, status: "Testing"),
            ],
            window: .twoWeeks, now: now
        )
        #expect(groups.testing.isEmpty)
        #expect(groups.done.map(\.key) == ["ACME-2"])
    }

    @Test("testing is ordered by priority like the lists above it")
    func orderedByPriority() {
        let groups = JiraGrouping.group(
            [
                issue("A-1", category: .inProgress, priority: .low, status: "Testing"),
                issue("A-2", category: .inProgress, priority: .critical, status: "Testing"),
                issue("A-3", category: .inProgress, priority: .medium, status: "Testing"),
            ],
            window: .twoWeeks, now: now
        )
        #expect(groups.testing.map(\.key) == ["A-2", "A-3", "A-1"])
    }

    @Test("nothing is lost or duplicated once testing is split out")
    func everyIssueLandsExactlyOnce() {
        let input = [
            issue("A-1", category: .toDo, status: "New"),
            issue("A-2", category: .inProgress, status: "In Progress"),
            issue("A-3", category: .inProgress, status: "Testing"),
            issue("A-4", category: .done, doneDaysAgo: 2),
        ]
        let groups = JiraGrouping.group(input, window: .twoWeeks, now: now)
        let landed = groups.toDo + groups.inProgress + groups.testing + groups.done

        #expect(Set(landed.map(\.key)) == Set(input.map(\.key)))
        #expect(groups.count == input.count)
    }
}

private func aged(
    _ key: String,
    category: JiraStatusCategory = .toDo,
    priority: JiraPriority = .medium,
    createdDaysAgo: Double
) -> JiraIssue {
    JiraIssue(
        key: key, summary: "summary", statusName: "To Do",
        statusCategory: category, issueType: "Task", priority: priority,
        updatedAt: now,
        createdAt: now.addingTimeInterval(-createdDaysAgo * 86_400)
    )
}

@Suite("JiraGrouping ordering")
struct JiraOrderingTests {

    @Test("priority decides first, in Jira's own order", arguments: [
        JiraStatusCategory.toDo, .inProgress,
    ])
    func priorityLeads(category: JiraStatusCategory) {
        let groups = JiraGrouping.group(
            [
                aged("A-1", category: category, priority: .lowest, createdDaysAgo: 1),
                aged("A-2", category: category, priority: .critical, createdDaysAgo: 9),
                aged("A-3", category: category, priority: .medium, createdDaysAgo: 2),
                aged("A-4", category: category, priority: .high, createdDaysAgo: 8),
                aged("A-5", category: category, priority: .low, createdDaysAgo: 3),
            ],
            window: .twoWeeks, now: now
        )
        let listed = category == .toDo ? groups.toDo : groups.inProgress
        #expect(listed.map(\.key) == ["A-2", "A-4", "A-3", "A-5", "A-1"])
    }

    @Test("the same priority falls back to the newest first", arguments: [
        JiraStatusCategory.toDo, .inProgress,
    ])
    func dateBreaksTies(category: JiraStatusCategory) {
        let groups = JiraGrouping.group(
            [
                aged("A-1", category: category, priority: .high, createdDaysAgo: 9),
                aged("A-2", category: category, priority: .high, createdDaysAgo: 1),
                aged("A-3", category: category, priority: .high, createdDaysAgo: 5),
            ],
            window: .twoWeeks, now: now
        )
        let listed = category == .toDo ? groups.toDo : groups.inProgress
        #expect(listed.map(\.key) == ["A-2", "A-3", "A-1"])
    }

    /// An issue whose creation date never arrived must not jump the queue.
    @Test("a missing date sorts last within its priority")
    func missingDateSortsLast() {
        let undated = JiraIssue(
            key: "A-9", summary: "s", statusName: "To Do", statusCategory: .toDo,
            issueType: "Task", priority: .high, updatedAt: now
        )
        let groups = JiraGrouping.group(
            [undated, aged("A-1", priority: .high, createdDaysAgo: 30)],
            window: .twoWeeks, now: now
        )
        #expect(groups.toDo.map(\.key) == ["A-1", "A-9"])
    }

    /// Two issues identical on both keys would otherwise reshuffle every poll.
    @Test("an exact tie is broken by the key, so the order is stable")
    func exactTieIsStable() {
        let groups = JiraGrouping.group(
            [
                aged("A-3", priority: .high, createdDaysAgo: 2),
                aged("A-1", priority: .high, createdDaysAgo: 2),
                aged("A-2", priority: .high, createdDaysAgo: 2),
            ],
            window: .twoWeeks, now: now
        )
        #expect(groups.toDo.map(\.key) == ["A-1", "A-2", "A-3"])
    }

    /// Done is a window of what finished recently, so recency still leads there
    /// — a critical issue closed a fortnight ago is not the headline.
    @Test("done stays ordered by when it finished")
    func doneKeepsRecency() {
        let groups = JiraGrouping.group(
            [
                issue("A-1", category: .done, priority: .critical, doneDaysAgo: 9),
                issue("A-2", category: .done, priority: .lowest, doneDaysAgo: 1),
            ],
            window: .twoWeeks, now: now
        )
        #expect(groups.done.map(\.key) == ["A-2", "A-1"])
    }
}
