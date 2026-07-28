import Foundation
import Testing
@testable import PRMasterCore

private func makePR(
    _ id: String,
    isDraft: Bool = false,
    mergeState: MergeStateStatus = .clean,
    checks: CheckState? = .success
) -> PullRequest {
    PullRequest(
        id: id,
        number: 1,
        title: "test",
        url: URL(string: "https://github.com/o/r/pull/1")!,
        repo: "o/r",
        isDraft: isDraft,
        headRefOid: "oid",
        mergeable: .mergeable,
        mergeState: mergeState,
        reviewDecision: nil,
        checks: checks,
        approvals: 0,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("NotificationDecider")
struct NotificationDeciderTests {

    @Test("a newly ready PR notifies and is recorded")
    func newlyReadyNotifies() {
        let pr = makePR("a")
        let result = NotificationDecider.decide(prs: [pr], notified: [])
        #expect(result.notify.map(\.id) == ["a"])
        #expect(result.updated == ["a"])
    }

    @Test("an already notified PR stays silent")
    func alreadyNotifiedIsSilent() {
        let result = NotificationDecider.decide(prs: [makePR("a")], notified: ["a"])
        #expect(result.notify.isEmpty)
        #expect(result.updated == ["a"], "must stay recorded so it keeps quiet next poll")
    }

    /// The re-arm case. A PR that goes ready, then gets a new commit pushed and
    /// drops back to blocked, must notify again when it returns to ready.
    @Test("leaving ready re-arms the PR")
    func leavingReadyReArms() {
        // Ready and notified.
        var state = NotificationDecider.decide(prs: [makePR("a")], notified: []).updated
        #expect(state == ["a"])

        // New commit lands: back to blocked. The ID must be dropped.
        state = NotificationDecider.decide(
            prs: [makePR("a", mergeState: .blocked)], notified: state
        ).updated
        #expect(state.isEmpty, "a PR that is no longer ready must not stay recorded")

        // Green again: it must notify a second time.
        let again = NotificationDecider.decide(prs: [makePR("a")], notified: state)
        #expect(again.notify.map(\.id) == ["a"])
    }

    @Test("a PR that disappears is pruned")
    func disappearedIsPruned() {
        let result = NotificationDecider.decide(prs: [], notified: ["a", "b"])
        #expect(result.notify.isEmpty)
        #expect(result.updated.isEmpty, "merged or closed PRs must not accumulate")
    }

    /// A PR that became ready while the app was closed has no previous
    /// snapshot, but also no recorded ID, so it correctly notifies on launch.
    @Test("a PR that went ready while the app was closed still notifies")
    func readyWhileClosed() {
        let result = NotificationDecider.decide(prs: [makePR("a")], notified: [])
        #expect(result.notify.map(\.id) == ["a"])
    }

    @Test("drafts never notify")
    func draftsNeverNotify() {
        let result = NotificationDecider.decide(prs: [makePR("a", isDraft: true)], notified: [])
        #expect(result.notify.isEmpty)
        #expect(result.updated.isEmpty)
    }

    @Test("only ready notifies", arguments: [
        (MergeStateStatus.behind, false),
        (MergeStateStatus.blocked, false),
        (MergeStateStatus.dirty, false),
        (MergeStateStatus.unknown, false),
        (MergeStateStatus.clean, true),
        (MergeStateStatus.unstable, true),
        (MergeStateStatus.hasHooks, true),
    ])
    func onlyReadyNotifies(state: MergeStateStatus, shouldNotify: Bool) {
        let result = NotificationDecider.decide(prs: [makePR("a", mergeState: state)], notified: [])
        #expect(result.notify.isEmpty != shouldNotify)
    }

    @Test("pending checks never notify")
    func pendingChecksNeverNotify() {
        let result = NotificationDecider.decide(
            prs: [makePR("a", checks: .pending)], notified: []
        )
        #expect(result.notify.isEmpty)
    }

    @Test("notifies only the newly ready PRs in a mixed list")
    func mixedList() {
        let prs = [
            makePR("ready-new"),
            makePR("ready-known"),
            makePR("blocked", mergeState: .blocked),
            makePR("draft", isDraft: true),
        ]
        let result = NotificationDecider.decide(prs: prs, notified: ["ready-known", "gone"])
        #expect(result.notify.map(\.id) == ["ready-new"])
        #expect(result.updated == ["ready-new", "ready-known"])
    }
}
