import Foundation
import Testing
@testable import PRMasterCore

private func makePR(
    _ id: String,
    headRefOid: String = "oid1",
    isDraft: Bool = false,
    mergeable: Mergeable = .mergeable,
    mergeState: MergeStateStatus = .behind,
    checks: CheckState? = .success
) -> PullRequest {
    PullRequest(
        id: id,
        number: 1,
        title: "title",
        url: URL(string: "https://github.com/acme/widget/pull/1")!,
        repo: "acme/widget",
        isPrivate: false,
        isDraft: isDraft,
        headRefOid: headRefOid,
        mergeable: mergeable,
        mergeState: mergeState,
        reviewDecision: nil,
        checks: checks,
        approvals: 0,
        updatedAt: Date(timeIntervalSince1970: 0),
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Branch update decider")
struct BranchUpdateDeciderTests {

    @Test("a behind PR with no recorded attempt is selected")
    func firstSighting() {
        let pr = makePR("PR_1")
        let decision = BranchUpdateDecider.decide(prs: [pr], attempted: [])
        #expect(decision.update.map(\.id) == ["PR_1"])
        #expect(decision.updated.count == 1)
    }

    /// The whole point of keying on the head oid: a failed update leaves the SHA
    /// untouched, so retrying would fail identically every 60 seconds forever.
    @Test("the same PR at the same head oid is never selected twice")
    func attemptIsNotRepeated() {
        let pr = makePR("PR_1", headRefOid: "sha_a")
        let first = BranchUpdateDecider.decide(prs: [pr], attempted: [])
        #expect(first.update.count == 1)

        let second = BranchUpdateDecider.decide(prs: [pr], attempted: first.updated)
        #expect(second.update.isEmpty)
    }

    /// A new commit is a new situation — the previous refusal says nothing
    /// about whether this one will merge cleanly.
    @Test("the same PR at a new head oid is selected again")
    func newHeadRearms() {
        let before = makePR("PR_1", headRefOid: "sha_a")
        let attempted = BranchUpdateDecider.decide(prs: [before], attempted: []).updated

        let after = makePR("PR_1", headRefOid: "sha_b")
        let decision = BranchUpdateDecider.decide(prs: [after], attempted: attempted)
        #expect(decision.update.map(\.id) == ["PR_1"])
    }

    /// Anything that outranks merge state in `Readiness.evaluate` — draft,
    /// conflicts, red or pending checks — must keep the PR out of this set.
    @Test("only PRs whose readiness is .behind are selected", arguments: [
        (MergeStateStatus.clean, CheckState?.some(.success), false, Mergeable.mergeable, false),
        (.blocked, .some(.success), false, .mergeable, false),
        (.dirty, .some(.success), false, .mergeable, false),
        (.unknown, .some(.success), false, .mergeable, false),
        (.unstable, .some(.success), false, .mergeable, false),
        // Behind, but something more urgent is wrong:
        (.behind, .some(.failure), false, .mergeable, false),
        (.behind, .some(.pending), false, .mergeable, false),
        (.behind, .some(.success), true, .mergeable, false),   // draft
        (.behind, .some(.success), false, .conflicting, false), // conflicted
        // Genuinely behind and otherwise fine:
        (.behind, .some(.success), false, .mergeable, true),
        (.behind, nil, false, .mergeable, true),                // repo has no CI
    ])
    func onlyBehindQualifies(
        mergeState: MergeStateStatus,
        checks: CheckState?,
        isDraft: Bool,
        mergeable: Mergeable,
        expected: Bool
    ) {
        let pr = makePR(
            "PR_1", isDraft: isDraft, mergeable: mergeable,
            mergeState: mergeState, checks: checks
        )
        let decision = BranchUpdateDecider.decide(prs: [pr], attempted: [])
        #expect(decision.update.isEmpty == !expected)
        #expect(decision.updated.isEmpty == !expected)
    }

    /// Self-cleaning: once a PR stops being behind its key drops out, so the
    /// set cannot grow without bound and the PR is re-armed for next time.
    @Test("keys for PRs that left the behind state drop out")
    func keysSelfClean() {
        let behind = makePR("PR_1", headRefOid: "sha_a")
        let attempted = BranchUpdateDecider.decide(prs: [behind], attempted: []).updated
        #expect(!attempted.isEmpty)

        let caughtUp = makePR("PR_1", headRefOid: "sha_a", mergeState: .clean)
        let decision = BranchUpdateDecider.decide(prs: [caughtUp], attempted: attempted)
        #expect(decision.updated.isEmpty)
    }

    /// A PR that vanishes from the search results must not leave its key behind.
    @Test("a PR that disappears from the list drops its key")
    func disappearedPRDropsOut() {
        let pr = makePR("PR_1")
        let attempted = BranchUpdateDecider.decide(prs: [pr], attempted: []).updated

        let decision = BranchUpdateDecider.decide(prs: [], attempted: attempted)
        #expect(decision.update.isEmpty)
        #expect(decision.updated.isEmpty)
    }

    @Test("selects every behind PR in one pass")
    func multiplePRs() {
        let prs = [makePR("PR_1"), makePR("PR_2"), makePR("PR_3", mergeState: .clean)]
        let decision = BranchUpdateDecider.decide(prs: prs, attempted: [])
        #expect(Set(decision.update.map(\.id)) == ["PR_1", "PR_2"])
    }

    /// Two PRs sharing a head oid across repos must not collide.
    @Test("keys distinguish PRs that share a head oid")
    func keysIncludeTheID() {
        let prs = [makePR("PR_1", headRefOid: "same"), makePR("PR_2", headRefOid: "same")]
        let decision = BranchUpdateDecider.decide(prs: prs, attempted: [])
        #expect(decision.updated.count == 2)
    }
}
