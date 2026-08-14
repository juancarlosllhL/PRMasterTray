import Foundation
import Testing
@testable import PRMasterCore

// MARK: - builders

private func merged(
    id: String = "PR_1",
    number: Int = 1204,
    repo: String = "acme/widget-service",
    repositoryID: String = "R_1",
    mergedAt: Date = Date(timeIntervalSince1970: 1_786_692_165),
    oid: String? = "9f4c1ab7e0d25c3184bb6f70a1e5d8c92374ef60",
    rollup: CheckState? = .success,
    contexts: [CheckContext] = []
) -> MergedPullRequest {
    MergedPullRequest(
        id: id,
        number: number,
        title: "paginate the widget catalogue endpoint",
        url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
        repo: repo,
        repositoryID: repositoryID,
        isPrivate: false,
        mergedAt: mergedAt,
        mergeCommitOid: oid,
        rollupState: rollup,
        contexts: contexts
    )
}

private func release(
    _ tag: String,
    oid: String = "ffffffffffffffffffffffffffffffffffffffff",
    createdAt: TimeInterval
) -> Release {
    Release(
        tagName: tag,
        url: URL(string: "https://github.com/acme/widget-service/releases/tag/\(tag)")!,
        tagCommitOid: oid,
        createdAt: Date(timeIntervalSince1970: createdAt)
    )
}

private let workflowURL = URL(string: "https://app.circleci.com/workflow/7c1d0e42")!
private let jobURL = URL(string: "https://circleci.com/gh/acme/widget-service/14841")!

@Suite("Shipment resolution")
struct ShipmentTests {

    // MARK: states that are not yet an answer

    /// GitHub takes seconds to materialise the merge commit. There is nothing to
    /// report yet, and nothing has gone wrong.
    @Test("a pull request with no merge commit yet is pending")
    func noMergeCommitIsPending() {
        let shipments = ShipmentResolver.resolve(
            merged: [merged(oid: nil, rollup: nil)],
            releases: [:],
            containment: [:]
        )
        #expect(shipments.first?.status == .pending)
    }

    /// A repository with no CI reports a null rollup. That is not "checks
    /// running" and must never render as building — there is nothing to wait for.
    @Test("a repository with no CI and no releases is pending, not building")
    func noCIIsPending() {
        let shipments = ShipmentResolver.resolve(
            merged: [merged(rollup: nil)],
            releases: ["R_1": []],
            containment: [:]
        )
        #expect(shipments.first?.status == .pending)
    }

    // MARK: CI states

    @Test("a failing rollup reports the failing check by name")
    func failingRollupNamesTheCheck() {
        let pr = merged(
            rollup: .failure,
            contexts: [
                CheckContext(name: "CD", state: .failure, url: workflowURL, isWorkflow: true),
                CheckContext(name: "ci/circleci: build", state: .success, url: jobURL, isWorkflow: false),
            ]
        )
        let shipments = ShipmentResolver.resolve(merged: [pr], releases: [:], containment: [:])
        #expect(shipments.first?.status == .failed(name: "CD", url: workflowURL))
    }

    /// Belt and braces. GitHub derives the rollup from the contexts, so the two
    /// should never disagree — but if they ever do, a named failing check is
    /// evidence and a summary that contradicts it is not. Reporting "released"
    /// over the top of a failed check is the worst answer available.
    @Test("a failing context is reported even if the rollup claims success")
    func failingContextOutranksAnAgreeableRollup() {
        let pr = merged(
            rollup: .success,
            contexts: [
                CheckContext(name: "CD", state: .failure, url: workflowURL, isWorkflow: true),
            ]
        )
        let shipments = ShipmentResolver.resolve(merged: [pr], releases: [:], containment: [:])
        #expect(shipments.first?.status == .failed(name: "CD", url: workflowURL))
    }

    @Test("a pending rollup is building, linked to the workflow")
    func pendingRollupIsBuilding() {
        let pr = merged(
            rollup: .pending,
            contexts: [
                CheckContext(name: "CD", state: .pending, url: workflowURL, isWorkflow: true),
            ]
        )
        let shipments = ShipmentResolver.resolve(merged: [pr], releases: [:], containment: [:])
        #expect(shipments.first?.status == .building(workflowURL))
    }

    // MARK: containment — the load-bearing rule

    /// The case the live API taught us: a merged pull request's release was cut
    /// ten minutes later, tagged on a *different* commit. Matching a version by
    /// comparing the tag commit to the merge commit would report this change as
    /// never released. Only containment gets it right.
    ///
    /// If this test is failing because someone reduced the resolver to OID
    /// equality, the resolver is wrong, not the test.
    @Test("a release tagged on a later commit still counts as containing the merge")
    func containmentNotEquality() {
        let pr = merged(mergedAt: Date(timeIntervalSince1970: 1_000), oid: "abc")
        let containing = release("v3.31.2", oid: "0eea2bd0", createdAt: 1_600)

        let shipments = ShipmentResolver.resolve(
            merged: [pr],
            releases: ["R_1": [containing]],
            containment: [ContainmentKey(pullRequestID: "PR_1", tagName: "v3.31.2"): true]
        )

        #expect(shipments.first?.status == .released(version: "v3.31.2", url: containing.url))
    }

    /// The release before the merge does not contain it, and compare says so.
    /// Reporting it would hand the user a version number that is missing their
    /// change — worse than reporting none.
    @Test("a release that does not contain the merge is never reported")
    func earlierReleaseNotReported() {
        let pr = merged(mergedAt: Date(timeIntervalSince1970: 1_000), oid: "abc")
        let earlier = release("v3.31.1", createdAt: 500)

        let shipments = ShipmentResolver.resolve(
            merged: [pr],
            releases: ["R_1": [earlier]],
            containment: [ContainmentKey(pullRequestID: "PR_1", tagName: "v3.31.1"): false]
        )

        #expect(shipments.first?.status != .released(version: "v3.31.1", url: earlier.url))
    }

    /// Several releases can contain a commit once time passes. The one the user
    /// wants is the first version their change appeared in, not the newest.
    @Test("the earliest containing release is the one reported")
    func earliestContainingWins() {
        let pr = merged(mergedAt: Date(timeIntervalSince1970: 1_000), oid: "abc")
        let first = release("v3.31.2", createdAt: 1_600)
        let later = release("v3.32.0", createdAt: 5_000)

        let shipments = ShipmentResolver.resolve(
            merged: [pr],
            releases: ["R_1": [later, first]],
            containment: [
                ContainmentKey(pullRequestID: "PR_1", tagName: "v3.31.2"): true,
                ContainmentKey(pullRequestID: "PR_1", tagName: "v3.32.0"): true,
            ]
        )

        #expect(shipments.first?.status == .released(version: "v3.31.2", url: first.url))
    }

    /// The whole point of the guard: an unanswered containment lookup must not
    /// become a guess. A wrong version number gets pasted into a Slack thread
    /// and then retracted.
    @Test("an unresolved containment stays building rather than inventing a version")
    func unresolvedContainmentNeverGuesses() {
        let pr = merged(
            mergedAt: Date(timeIntervalSince1970: 1_000),
            oid: "abc",
            contexts: [CheckContext(name: "CD", state: .success, url: workflowURL, isWorkflow: true)]
        )
        let candidate = release("v3.31.2", createdAt: 1_600)

        // No entry at all: the containment request failed or has not run yet.
        let shipments = ShipmentResolver.resolve(
            merged: [pr],
            releases: ["R_1": [candidate]],
            containment: [:]
        )

        #expect(shipments.first?.status == .building(workflowURL))
    }

    // MARK: where the row goes

    /// The pipeline while it is worth watching, the release once there is one,
    /// and never nowhere.
    @Test("each status has a destination worth opening")
    func destinations() {
        let pr = merged()
        let releaseURL = URL(string: "https://github.com/acme/widget-service/releases/tag/v1")!

        #expect(Shipment(pr: pr, status: .pending).destination == pr.url)
        #expect(Shipment(pr: pr, status: .building(workflowURL)).destination == workflowURL)
        #expect(
            Shipment(pr: pr, status: .failed(name: "CD", url: workflowURL)).destination
                == workflowURL
        )
        #expect(
            Shipment(pr: pr, status: .released(version: "v1", url: releaseURL)).destination
                == releaseURL
        )
    }

    // MARK: candidates

    /// Containment is only worth asking about for releases that could possibly
    /// contain the merge. Asking about every release would cost a request per
    /// tag for no gain.
    @Test("only releases created at or after the merge are candidates")
    func candidatesExcludeOlderReleases() {
        let pr = merged(mergedAt: Date(timeIntervalSince1970: 1_000), oid: "abc")
        let before = release("v3.31.1", createdAt: 500)
        let after = release("v3.31.2", createdAt: 1_600)

        let candidates = ShipmentResolver.candidates(
            merged: [pr],
            releases: ["R_1": [before, after]]
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.release.tagName == "v3.31.2")
        #expect(candidates.first?.pullRequest.id == "PR_1")
    }

    @Test("a pull request with no merge commit yields no candidates to compare")
    func noOidNoCandidates() {
        let candidates = ShipmentResolver.candidates(
            merged: [merged(oid: nil)],
            releases: ["R_1": [release("v3.31.2", createdAt: 9_999)]]
        )
        #expect(candidates.isEmpty)
    }
}

@Suite("Workflow link")
struct WorkflowLinkTests {

    private let fallback = URL(string: "https://github.com/acme/widget-service/pull/1204")!

    /// A StatusContext URL lands on one job of a pipeline; a CheckRun URL lands
    /// on the whole workflow. The workflow is what the user came to look at.
    @Test("prefers the workflow link over a single job's link")
    func prefersWorkflow() {
        let picked = WorkflowLink.pick(
            from: [
                CheckContext(name: "ci/circleci: build", state: .pending, url: jobURL, isWorkflow: false),
                CheckContext(name: "CD", state: .pending, url: workflowURL, isWorkflow: true),
            ],
            fallback: fallback
        )
        #expect(picked == workflowURL)
    }

    @Test("prefers the running workflow over one that already finished")
    func prefersRunning() {
        let finished = URL(string: "https://app.circleci.com/workflow/finished")!
        let picked = WorkflowLink.pick(
            from: [
                CheckContext(name: "on_master", state: .success, url: finished, isWorkflow: true),
                CheckContext(name: "CD", state: .pending, url: workflowURL, isWorkflow: true),
            ],
            fallback: fallback
        )
        #expect(picked == workflowURL)
    }

    @Test("prefers a failing workflow when nothing is still running")
    func prefersFailing() {
        let failed = URL(string: "https://app.circleci.com/workflow/failed")!
        let picked = WorkflowLink.pick(
            from: [
                CheckContext(name: "on_master", state: .success, url: workflowURL, isWorkflow: true),
                CheckContext(name: "CD", state: .failure, url: failed, isWorkflow: true),
            ],
            fallback: fallback
        )
        #expect(picked == failed)
    }

    /// Better to open the pull request than to have a row that does nothing when
    /// clicked.
    @Test("falls back to the pull request when no context carries a URL")
    func fallsBack() {
        let picked = WorkflowLink.pick(
            from: [CheckContext(name: "CD", state: .pending, url: nil, isWorkflow: true)],
            fallback: fallback
        )
        #expect(picked == fallback)
    }

    @Test("falls back when there are no contexts at all")
    func fallsBackOnEmpty() {
        #expect(WorkflowLink.pick(from: [], fallback: fallback) == fallback)
    }
}
