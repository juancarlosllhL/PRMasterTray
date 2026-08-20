import Foundation
import Testing
@testable import PRMasterCore

private let mergedAt = Date(timeIntervalSince1970: 1_000)

private func merged(id: String = "PR_1") -> MergedPullRequest {
    MergedPullRequest(
        id: id,
        number: 1204,
        title: "paginate the widget catalogue endpoint",
        url: URL(string: "https://github.com/acme/widget-service/pull/1204")!,
        repo: "acme/widget-service",
        repositoryID: "R_1",
        isPrivate: false,
        mergedAt: mergedAt,
        mergeCommitOid: "9f4c1ab7",
        rollupState: .success,
        contexts: []
    )
}

private func release(_ tag: String, createdAt: TimeInterval) -> Release {
    Release(
        tagName: tag,
        url: URL(string: "https://github.com/acme/widget-service/releases/tag/\(tag)")!,
        tagCommitOid: "ffff",
        createdAt: Date(timeIntervalSince1970: createdAt)
    )
}

private func promoted(_ environment: DeployEnvironment, _ region: String, _ version: String) -> PromotedVersion {
    PromotedVersion(
        file: PromotionFile(environment: environment, region: region),
        version: version
    )
}

private func key(_ tag: String) -> ContainmentKey {
    ContainmentKey(pullRequestID: "PR_1", tagName: tag)
}

private func environments(
    promotions: [PromotedVersion],
    releases: [Release],
    containment: [ContainmentKey: Bool]
) -> [EnvironmentState] {
    ShipmentResolver.resolve(
        merged: [merged()],
        releases: ["R_1": releases],
        containment: containment,
        promotions: ["acme/widget-service": promotions]
    ).first?.environments ?? []
}

@Suite("Deployment resolution")
struct DeploymentResolutionTests {

    // MARK: the two answers worth giving

    @Test("an environment whose promoted release contains the merge is carrying it")
    func carrying() throws {
        let states = environments(
            promotions: [promoted(.staging, "euw1", "3.32.0")],
            releases: [release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.32.0"): true]
        )
        #expect(states == [EnvironmentState(environment: .staging, status: .carrying(version: "3.32.0"))])
    }

    @Test("an environment on a release without the merge is still awaiting it")
    func awaiting() throws {
        let states = environments(
            promotions: [promoted(.production, "euw1", "3.32.0")],
            releases: [release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.32.0"): false]
        )
        #expect(states == [EnvironmentState(environment: .production, status: .awaiting(version: "3.32.0"))])
    }

    // MARK: the rule this whole step exists for

    /// The environment is on a *higher* version than the release that carries
    /// this change, and containment says the change is not in it — a cherry-pick
    /// or a release cut from another branch. Anything comparing version numbers
    /// would report this as deployed. It is not.
    ///
    /// If this test fails because someone reduced the resolver to a semver
    /// comparison, the resolver is wrong, not the test.
    @Test("a higher promoted version does not imply the change is there")
    func higherVersionIsNotEvidence() {
        let states = environments(
            promotions: [promoted(.production, "euw1", "3.32.0")],
            releases: [release("v3.31.2", createdAt: 1_500), release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.31.2"): true, key("v3.32.0"): false]
        )
        #expect(states.first?.status == .awaiting(version: "3.32.0"))
    }

    /// And the converse: a lower version that provably contains the merge is
    /// carrying it, however the numbers compare.
    @Test("a lower promoted version that contains the merge is carrying it")
    func lowerVersionCanCarry() {
        let states = environments(
            promotions: [promoted(.production, "euw1", "3.31.2")],
            releases: [release("v3.31.2", createdAt: 1_500), release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.31.2"): true]
        )
        #expect(states.first?.status == .carrying(version: "3.31.2"))
    }

    // MARK: what must never become a guess

    @Test("an unanswered containment is unknown rather than a guess")
    func unansweredIsUnknown() {
        let states = environments(
            promotions: [promoted(.staging, "euw1", "3.32.0")],
            releases: [release("v3.32.0", createdAt: 2_000)],
            containment: [:]
        )
        #expect(states.first?.status == .unknown)
    }

    /// The promoted version is older than the release page reaches, so nothing
    /// identifies it. Reporting it as awaiting would be a guess in the other
    /// direction.
    @Test("a promoted version matching no known release is unknown")
    func unmatchedVersionIsUnknown() {
        let states = environments(
            promotions: [promoted(.production, "euw1", "2.9.9")],
            releases: [release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.32.0"): true]
        )
        #expect(states.first?.status == .unknown)
    }

    /// A release cut before the merge cannot contain it. That is answerable from
    /// the clock alone, so it is settled without spending a request.
    @Test("a release older than the merge is awaiting without needing an answer")
    func olderReleaseNeedsNoAnswer() {
        let states = environments(
            promotions: [promoted(.production, "euw1", "3.30.0")],
            releases: [release("v3.30.0", createdAt: 500)],
            containment: [:]
        )
        #expect(states.first?.status == .awaiting(version: "3.30.0"))
    }

    /// The `v` prefix is a tag convention; the values file carries the bare
    /// version. Failing to join them would leave every environment unknown.
    @Test("the tag's v prefix does not prevent the match")
    func matchesAcrossThePrefix() {
        let states = environments(
            promotions: [promoted(.staging, "euw1", "3.32.0")],
            releases: [release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.32.0"): true]
        )
        #expect(states.first?.status == .carrying(version: "3.32.0"))
    }

    // MARK: across regions

    @Test("an environment is carrying only when every region carries")
    func everyRegionMustCarry() {
        let states = environments(
            promotions: [
                promoted(.staging, "euw1", "3.32.0"),
                promoted(.staging, "use2", "3.31.2"),
            ],
            releases: [release("v3.31.2", createdAt: 1_500), release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.32.0"): true, key("v3.31.2"): false]
        )
        #expect(states.first?.status == .awaiting(version: "3.31.2"))
    }

    @Test("every region carrying reports the environment as carrying")
    func allRegionsCarry() {
        let states = environments(
            promotions: [
                promoted(.staging, "euw1", "3.32.0"),
                promoted(.staging, "use2", "3.31.2"),
            ],
            releases: [release("v3.31.2", createdAt: 1_500), release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.32.0"): true, key("v3.31.2"): true]
        )
        #expect(states.first?.status == .carrying(version: "3.31.2"))
    }

    /// A region that provably lacks the change settles the environment even if
    /// another region has no answer: proof outranks an unknown.
    @Test("a region proven to lack the change outranks another region's unknown")
    func provenAbsenceOutranksUnknown() {
        let states = environments(
            promotions: [
                promoted(.staging, "euw1", "3.32.0"),
                promoted(.staging, "use2", "3.31.2"),
            ],
            releases: [release("v3.31.2", createdAt: 1_500), release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.31.2"): false]
        )
        #expect(states.first?.status == .awaiting(version: "3.31.2"))
    }

    @Test("one region unanswered leaves the environment unknown")
    func oneUnknownRegion() {
        let states = environments(
            promotions: [
                promoted(.staging, "euw1", "3.32.0"),
                promoted(.staging, "use2", "3.31.2"),
            ],
            releases: [release("v3.31.2", createdAt: 1_500), release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.32.0"): true]
        )
        #expect(states.first?.status == .unknown)
    }

    // MARK: a rollout still in flight

    /// The version reported is the lowest across the regions, so the row needs
    /// to know the regions disagreed or "prod 3.31.1" reads as settled when one
    /// region has already moved past it.
    @Test("regions holding different versions are reported as not agreeing")
    func rolloutInFlightIsVisible() {
        let states = environments(
            promotions: [
                promoted(.staging, "euw1", "3.32.0"),
                promoted(.staging, "use2", "3.31.2"),
            ],
            releases: [release("v3.31.2", createdAt: 1_500), release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.32.0"): true, key("v3.31.2"): true]
        )
        #expect(states.first?.regionsAgree == false)
        #expect(states.first?.status == .carrying(version: "3.31.2"))
    }

    @Test("regions holding the same version agree")
    func settledRolloutAgrees() {
        let states = environments(
            promotions: [
                promoted(.staging, "euw1", "3.32.0"),
                promoted(.staging, "use2", "3.32.0"),
            ],
            releases: [release("v3.32.0", createdAt: 2_000)],
            containment: [key("v3.32.0"): true]
        )
        #expect(states.first?.regionsAgree == true)
    }

    // MARK: absence

    @Test("a repository with no known apps reports no environments at all")
    func noPromotions() {
        let shipments = ShipmentResolver.resolve(
            merged: [merged()],
            releases: ["R_1": [release("v3.32.0", createdAt: 2_000)]],
            containment: [key("v3.32.0"): true]
        )
        #expect(shipments.first?.environments.isEmpty == true)
    }

    // MARK: no new request

    /// Environment versions need no candidates of their own: every release newer
    /// than the merge is already asked about, which is exactly the set an
    /// environment can be on and have the change. Adding them again would spend
    /// a second request to learn what the first already answered.
    @Test("the release an environment is on is already a containment candidate")
    func environmentReleasesAreAlreadyAsked() {
        let candidates = ShipmentResolver.candidates(
            merged: [merged()],
            releases: ["R_1": [release("v3.32.0", createdAt: 2_000)]]
        )
        #expect(candidates.map(\.release.tagName) == ["v3.32.0"])
    }

    // MARK: versions nothing in hand identifies

    private func unidentified(
        merged: [MergedPullRequest],
        releases: [Release],
        promotions: [PromotedVersion]
    ) -> [ReleaseTagRequest] {
        ShipmentResolver.unidentifiedVersions(
            merged: merged,
            releases: ["R_1": releases],
            promotions: ["acme/widget-service": promotions]
        )
    }

    /// The `v` is dropped on the way in, so the tag and the promoted version are
    /// the same thing here and nothing has to be asked.
    @Test("a promoted version a fetched release accounts for is not looked up")
    func identifiedVersionIsNotLookedUp() {
        #expect(unidentified(
            merged: [merged()],
            releases: [release("v3.32.0", createdAt: 2_000)],
            promotions: [promoted(.staging, "euw1", "3.32.0")]
        ).isEmpty)
    }

    /// The case the chips were missing for: production lags further behind than
    /// the window's release depth reaches, so nothing in hand names its version.
    @Test("a promoted version no fetched release accounts for is looked up")
    func laggingVersionIsLookedUp() {
        #expect(unidentified(
            merged: [merged()],
            releases: [release("v3.40.0", createdAt: 2_000)],
            promotions: [promoted(.production, "euw1", "3.31.1")]
        ) == [
            ReleaseTagRequest(repo: "acme/widget-service", repositoryID: "R_1", version: "3.31.1")
        ])
    }

    @Test("one version across several regions and environments is one request")
    func regionsShareOneRequest() {
        #expect(unidentified(
            merged: [merged()],
            releases: [],
            promotions: [
                promoted(.staging, "euw1", "3.31.1"),
                promoted(.staging, "use2", "3.31.1"),
                promoted(.production, "euw1", "3.31.1"),
            ]
        ).count == 1)
    }

    /// Two merges in one repository see the same environments, so asking twice
    /// would spend a request to be told the same thing.
    @Test("two merges in one repository share one request")
    func mergesShareOneRequest() {
        #expect(unidentified(
            merged: [merged(), merged(id: "PR_2")],
            releases: [],
            promotions: [promoted(.production, "euw1", "3.31.1")]
        ).count == 1)
    }

    @Test("distinct promoted versions are asked about separately")
    func distinctVersionsAreBothAsked() {
        let requests = unidentified(
            merged: [merged()],
            releases: [],
            promotions: [
                promoted(.staging, "euw1", "3.40.0"),
                promoted(.production, "euw1", "3.31.1"),
            ]
        )
        #expect(Set(requests.map(\.version)) == ["3.40.0", "3.31.1"])
    }

    @Test("a repository with no promotions is not asked about")
    func noPromotionsNoRequests() {
        #expect(unidentified(
            merged: [merged()],
            releases: [release("v3.40.0", createdAt: 2_000)],
            promotions: []
        ).isEmpty)
    }
}
