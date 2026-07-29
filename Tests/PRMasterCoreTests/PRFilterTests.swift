import Foundation
import Testing
@testable import PRMasterCore

private func makePR(
    _ id: String = "PR_1",
    repo: String = "acme/widget-service",
    isPrivate: Bool = false
) -> PullRequest {
    PullRequest(
        id: id, number: 1, title: "test",
        url: URL(string: "https://github.com/\(repo)/pull/1")!,
        repo: repo, isPrivate: isPrivate, isDraft: false, headRefOid: "oid",
        mergeable: .mergeable, mergeState: .clean,
        reviewDecision: nil, checks: .success, approvals: 0,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("PullRequest.organization")
struct OrganizationTests {

    @Test("the owner half of nameWithOwner is the organization", arguments: [
        ("acme/widget-service", "acme"),
        ("acme-corp/infra", "acme-corp"),
        // A personal repository: the owner is an account, not an organization,
        // and the filter treats it the same way.
        ("jcll/dotfiles", "jcll"),
    ])
    func splitsOnSlash(repo: String, expected: String) {
        #expect(makePR(repo: repo).organization == expected)
    }

    /// Repository names cannot contain a slash, so only the first one counts.
    @Test("only the first slash separates owner from name")
    func splitsOnFirstSlash() {
        #expect(makePR(repo: "acme/widget/service").organization == "acme")
    }
}

@Suite("PRFilter")
struct PRFilterTests {

    // MARK: defaults

    /// The default has to match what the app did before the setting existed, or
    /// installing an update would silently empty somebody's list.
    @Test("the default filter hides nothing")
    func defaultShowsEverything() {
        let filter = PRFilter()
        #expect(filter.includes(makePR(repo: "acme/widget-service")))
        #expect(filter.includes(makePR(repo: "other/thing", isPrivate: true)))
        #expect(filter.isActive == false)
    }

    // MARK: organizations

    @Test("a hidden organization is excluded")
    func hiddenOrganizationExcluded() {
        let filter = PRFilter(hiddenOrganizations: ["acme"])
        #expect(filter.includes(makePR(repo: "acme/widget-service")) == false)
        #expect(filter.isActive)
    }

    @Test("hiding one organization leaves the others alone")
    func otherOrganizationsUnaffected() {
        let filter = PRFilter(hiddenOrganizations: ["acme"])
        #expect(filter.includes(makePR(repo: "widgetco/api")))
    }

    /// A blocklist is the load-bearing choice: an allowlist would hide the first
    /// pull request opened in an organization the user has never seen listed.
    @Test("an unknown organization is shown, not hidden")
    func unknownOrganizationIsShown() {
        #expect(PRFilter(hiddenOrganizations: ["acme"]).shows(organization: "brand-new"))
    }

    @Test("setOrganization hides and unhides")
    func setOrganizationRoundTrips() {
        var filter = PRFilter()
        filter.setOrganization("acme", shown: false)
        #expect(filter.hiddenOrganizations == ["acme"])
        filter.setOrganization("acme", shown: true)
        #expect(filter.hiddenOrganizations.isEmpty)
    }

    @Test("hiding an already hidden organization is idempotent")
    func setOrganizationIdempotent() {
        var filter = PRFilter(hiddenOrganizations: ["acme"])
        filter.setOrganization("acme", shown: false)
        #expect(filter.hiddenOrganizations == ["acme"])
    }

    // MARK: private repositories

    @Test("private pull requests are hidden when the switch is off")
    func privateHidden() {
        let filter = PRFilter(showsPrivateRepositories: false)
        #expect(filter.includes(makePR(isPrivate: true)) == false)
        #expect(filter.includes(makePR(isPrivate: false)))
        #expect(filter.isActive)
    }

    @Test("private pull requests are shown when the switch is on")
    func privateShown() {
        #expect(PRFilter(showsPrivateRepositories: true).includes(makePR(isPrivate: true)))
    }

    /// The two controls are independent, and either one alone is enough to hide
    /// a pull request.
    @Test("a public pull request in a hidden organization is still hidden")
    func organizationBeatsVisibility() {
        let filter = PRFilter(hiddenOrganizations: ["acme"], showsPrivateRepositories: true)
        #expect(filter.includes(makePR(repo: "acme/widget-service")) == false)
    }

    // MARK: apply

    @Test("apply keeps the fetch order")
    func applyPreservesOrder() {
        let filter = PRFilter(hiddenOrganizations: ["acme"])
        let prs = [
            makePR("a", repo: "widgetco/api"),
            makePR("b", repo: "acme/widget-service"),
            makePR("c", repo: "widgetco/web"),
        ]
        #expect(filter.apply(to: prs).map(\.id) == ["a", "c"])
    }

    @Test("apply can legitimately return nothing")
    func applyCanEmpty() {
        let filter = PRFilter(hiddenOrganizations: ["acme"])
        #expect(filter.apply(to: [makePR("a")]).isEmpty)
    }
}
