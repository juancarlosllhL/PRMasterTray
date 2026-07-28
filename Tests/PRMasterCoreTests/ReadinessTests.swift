import Foundation
import Testing
@testable import PRMasterCore

/// Builds a PR that is ready to merge, so each test varies exactly one field.
private func makePR(
    isDraft: Bool = false,
    mergeable: Mergeable = .mergeable,
    mergeState: MergeStateStatus = .clean,
    reviewDecision: ReviewDecision? = nil,
    checks: CheckState? = .success
) -> PullRequest {
    PullRequest(
        id: "PR_kwDOtest",
        number: 1,
        title: "test",
        url: URL(string: "https://github.com/o/r/pull/1")!,
        repo: "o/r",
        isDraft: isDraft,
        headRefOid: "deadbeef",
        mergeable: mergeable,
        mergeState: mergeState,
        reviewDecision: reviewDecision,
        checks: checks,
        approvals: 0,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Readiness.evaluate")
struct ReadinessTests {

    // MARK: exhaustive mapping

    /// Criterion: the suite covers all seven MergeStateStatus values. Pairing
    /// each with its expected outcome makes the whole rule readable at a glance.
    @Test("every merge state maps to its expected readiness", arguments: [
        (MergeStateStatus.clean, Readiness.ready),
        (MergeStateStatus.unstable, Readiness.ready),
        (MergeStateStatus.hasHooks, Readiness.ready),
        (MergeStateStatus.behind, Readiness.behind),
        (MergeStateStatus.unknown, Readiness.checksPending),
        (MergeStateStatus.blocked, Readiness.blocked),
        (MergeStateStatus.dirty, Readiness.blocked),
    ])
    func mergeStateMapping(state: MergeStateStatus, expected: Readiness) {
        #expect(makePR(mergeState: state).readiness == expected)
    }

    /// Guards the table above: if GitHub ever grows an eighth value, this fails
    /// rather than letting an unmapped state slip through untested.
    @Test("the mapping table is exhaustive")
    func tableIsExhaustive() {
        #expect(MergeStateStatus.allCases.count == 7)
    }

    // MARK: precedence

    @Test("draft beats everything, even a mergeable PR")
    func draftWins() {
        #expect(makePR(isDraft: true, mergeState: .clean).readiness == .draft)
    }

    @Test("conflicts beat a clean merge state")
    func conflictWins() {
        #expect(makePR(mergeable: .conflicting, mergeState: .clean).readiness == .conflicted)
    }

    @Test("failing checks beat a clean merge state", arguments: [CheckState.failure, CheckState.error])
    func failingChecksWin(state: CheckState) {
        #expect(makePR(mergeState: .clean, checks: state).readiness == .checksFailing)
    }

    /// EXPECTED means a required check is declared but has not reported yet,
    /// which is pending, not success.
    @Test("running or expected checks beat a clean merge state",
          arguments: [CheckState.pending, CheckState.expected])
    func pendingChecksWin(state: CheckState) {
        #expect(makePR(mergeState: .clean, checks: state).readiness == .checksPending)
    }

    // MARK: the traps

    /// A repo with no CI reports a null rollup. Treating that as pending would
    /// mean such PRs could never become ready.
    @Test("a repo with no CI is still ready")
    func noCIIsReady() {
        #expect(makePR(mergeState: .clean, checks: nil).readiness == .ready)
    }

    /// Taken from a real PR that reported `reviewDecision: null` and
    /// `mergeable: MERGEABLE` while `mergeStateStatus` was BLOCKED. A rule keyed
    /// on review state would wrongly call this ready.
    @Test("no review required but blocked is still blocked")
    func nilReviewDecisionButBlocked() {
        #expect(makePR(mergeState: .blocked, reviewDecision: nil).readiness == .blocked)
    }

    /// UNKNOWN appears while GitHub recomputes mergeability after a push.
    /// Reaching ready here would fire a notification on every single push.
    @Test("unknown is never ready")
    func unknownIsNeverReady() {
        #expect(makePR(mergeState: .unknown).readiness != .ready)
    }

    @Test("an approved, green, clean PR is ready")
    func happyPath() {
        let pr = makePR(mergeState: .clean, reviewDecision: .approved, checks: .success)
        #expect(pr.readiness == .ready)
    }
}
