import Foundation
import Testing
@testable import PRMasterCore

private let team = Team(
    combinedSlug: "Lansweeper/asset-cortex",
    organization: "Lansweeper",
    name: "Asset Cortex"
)

private func request(
    id: String = "PR_1",
    repo: String = "Lansweeper/LECAIChatAssistant",
    isPrivate: Bool = false,
    title: String = "coalesce the processor counts",
    author: String = "pedrojcalvo",
    checks: CheckState? = .success,
    reviewDecision: ReviewDecision? = .reviewRequired,
    createdAt: Date = Date(timeIntervalSince1970: 1_000),
    additions: Int = 40,
    deletions: Int = 10,
    changedFiles: Int = 3,
    teams: [Team] = [team]
) -> ReviewRequest {
    ReviewRequest(
        id: id,
        number: 909,
        title: title,
        url: URL(string: "https://github.com/\(repo)/pull/909")!,
        repo: repo,
        isPrivate: isPrivate,
        author: author,
        headRefOid: "a408f981d07bce9ebd7654b81f47883be1baf98e",
        checks: checks,
        reviewDecision: reviewDecision,
        createdAt: createdAt,
        updatedAt: Date(timeIntervalSince1970: 2_000),
        additions: additions,
        deletions: deletions,
        changedFiles: changedFiles,
        teams: teams
    )
}

@Suite("Review state")
struct ReviewStateTests {

    // MARK: - The precedence table

    /// The whole rule, stated as a table rather than as prose.
    ///
    /// `changesRequested` outranks the checks deliberately: it is a colleague's
    /// decision about the content, and approving over the top of one overrides a
    /// person rather than a build. The checks then outrank `approved` for the same
    /// reason `Readiness` puts them above merge state — a red pull request is not
    /// waiting for another approval, it is waiting for a fix.
    @Test("state is decided by review decision, then checks", arguments: [
        // Changes requested dominates, whatever the checks are doing.
        (ReviewDecision.changesRequested, CheckState.success, ReviewState.changesRequested),
        (.changesRequested, .failure, .changesRequested),
        (.changesRequested, .pending, .changesRequested),
        // Then the checks.
        (.reviewRequired, .failure, .checksFailing),
        (.reviewRequired, .error, .checksFailing),
        (.reviewRequired, .pending, .checksPending),
        (.reviewRequired, .expected, .checksPending),
        (.approved, .failure, .checksFailing),
        (.approved, .pending, .checksPending),
        // Then whether somebody has already approved.
        (.approved, .success, .approved),
        (.reviewRequired, .success, .awaiting),
    ])
    func precedence(
        decision: ReviewDecision, checks: CheckState, expected: ReviewState
    ) {
        #expect(request(checks: checks, reviewDecision: decision).state == expected)
    }

    /// `nil` checks means the repository has no CI at all, which is not the same
    /// as checks still running — the distinction `PullRequest.checks` documents
    /// and `Readiness.evaluate` honours. Treating it as pending would leave every
    /// pull request in a CI-less repository permanently unreviewable.
    @Test("no CI at all is not the same as checks running")
    func absentChecksAreNotPending() {
        #expect(request(checks: nil, reviewDecision: .reviewRequired).state == .awaiting)
        #expect(request(checks: nil, reviewDecision: .approved).state == .approved)
        #expect(request(checks: nil, reviewDecision: .changesRequested).state == .changesRequested)
    }

    /// A repository that requires no review at all reports `nil` rather than
    /// `reviewRequired`. It still reached this list, so a team was asked.
    @Test("a nil review decision still reads as awaiting")
    func absentDecision() {
        #expect(request(checks: .success, reviewDecision: nil).state == .awaiting)
        #expect(request(checks: nil, reviewDecision: nil).state == .awaiting)
        #expect(request(checks: .failure, reviewDecision: nil).state == .checksFailing)
    }

    // MARK: - Presentation

    @Test("every state has a label and a symbol")
    func everyStateIsDrawable() {
        #expect(ReviewState.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(ReviewState.allCases.allSatisfy { !$0.symbolName.isEmpty })
    }

    /// In monochrome the colour is gone and the glyph is most of what is left, so
    /// two states sharing one would be indistinguishable.
    @Test("no two states share a symbol")
    func symbolsAreDistinct() {
        let symbols = Set(ReviewState.allCases.map(\.symbolName))
        #expect(symbols.count == ReviewState.allCases.count)
    }

    /// `checkmark.circle.fill` means "you can merge this" everywhere else in the
    /// popover. Here the state means somebody else has approved and the team's
    /// request is still open, which is a different claim — the same call
    /// `ShipmentRowView` makes about not borrowing the readiness checkmark.
    @Test("approved does not borrow the ready-to-merge glyph")
    func approvedHasItsOwnGlyph() {
        #expect(ReviewState.approved.symbolName != Readiness.ready.symbolName)
    }

    /// `PaletteTests` proves a contrast floor across every `ReadinessTint`, so a
    /// seventh case would arrive unproven. This pins the count that claim rests
    /// on: these states are drawn from the existing six and add none.
    @Test("the tints are the six already proven for contrast")
    func tintsAreProven() {
        #expect(ReadinessTint.allCases.count == 6)
        #expect(ReviewState.changesRequested.tint == .orange)
        #expect(ReviewState.checksFailing.tint == .red)
        #expect(ReviewState.checksPending.tint == .yellow)
        #expect(ReviewState.approved.tint == .green)
        #expect(ReviewState.awaiting.tint == .blue)
    }

    /// The same rule the open and merged rows follow: a raw `:bug:` in a list
    /// where the two sections above it render the emoji reads as a bug.
    @Test("gitmoji shortcodes render like every other row")
    func displayTitleRendersShortcodes() {
        #expect(request(title: ":bug: fix the thing").displayTitle == "🐛 fix the thing")
    }

    // MARK: - The repository filter

    /// The load-bearing conformance. Without it the "hide pull requests from
    /// private repositories" switch would go on hiding the user's own rows while
    /// leaking other people's private ones into the section below — in a menu bar
    /// item that is often on screen while somebody else is looking at it.
    @Test("the private repositories switch reaches this section too")
    func privateIsHidden() {
        let hidden = PRFilter(showsPrivateRepositories: false)

        #expect(hidden.includes(request(isPrivate: true)) == false)
        #expect(hidden.includes(request(isPrivate: false)))
    }

    /// Hiding an organization has to mean hiding it everywhere, for the reason
    /// `PRFilter` gives about a merge: an organization the user chose not to see
    /// must not reappear in another section.
    @Test("a hidden organization is hidden here as well")
    func hiddenOrganizationApplies() {
        let filter = PRFilter(hiddenOrganizations: ["Lansweeper"])

        #expect(filter.includes(request(repo: "Lansweeper/LECAIChatAssistant")) == false)
        #expect(filter.includes(request(repo: "acme/widget-service")))
    }

    @Test("apply keeps the order it was given")
    func applyPreservesOrder() {
        let requests = [
            request(id: "PR_1", repo: "Lansweeper/a"),
            request(id: "PR_2", repo: "acme/b"),
            request(id: "PR_3", repo: "Lansweeper/c"),
        ]

        let kept = PRFilter(hiddenOrganizations: ["acme"]).apply(to: requests)
        #expect(kept.map(\.id) == ["PR_1", "PR_3"])
    }

    // MARK: - Attribution

    /// A pull request can be requested from two of the user's teams at once —
    /// seen live on Lansweeper/LEC-Honeycomb-tf 256, asked of both platform and
    /// datanauts. Carrying an array is what lets that be one row instead of two.
    @Test("a request can name more than one of your teams")
    func carriesEveryTeamAsked() {
        let datanauts = Team(
            combinedSlug: "Lansweeper/datanauts", organization: "Lansweeper", name: "Datanauts"
        )

        #expect(request(teams: [team, datanauts]).teams.count == 2)
    }

    @Test("the organization is split off the repository the same way everywhere")
    func organizationMatchesTheOtherModels() {
        #expect(request(repo: "Lansweeper/LECLuzmoPlugin").organization == "Lansweeper")
    }
}
