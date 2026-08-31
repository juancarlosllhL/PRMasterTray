import Foundation
import Testing
@testable import PRMasterCore

private let team = Team(
    combinedSlug: "Lansweeper/asset-cortex",
    organization: "Lansweeper",
    name: "Asset Cortex"
)

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func pr(
    title: String = "coalesce the processor counts",
    additions: Int = 200,
    deletions: Int = 60,
    changedFiles: Int = 5,
    checks: CheckState? = .success,
    reviewDecision: ReviewDecision? = .reviewRequired,
    openedDaysAgo: Double = 3
) -> ReviewRequest {
    ReviewRequest(
        id: "PR_1",
        number: 909,
        title: title,
        url: URL(string: "https://github.com/Lansweeper/x/pull/909")!,
        repo: "Lansweeper/x",
        isPrivate: false,
        author: "pedrojcalvo",
        headRefOid: "a408f981",
        checks: checks,
        reviewDecision: reviewDecision,
        createdAt: now.addingTimeInterval(-openedDaysAgo * 86_400),
        updatedAt: now,
        additions: additions,
        deletions: deletions,
        changedFiles: changedFiles,
        teams: [team]
    )
}

@Suite("Approval quips")
struct ApprovalQuipTests {

    // MARK: - The shape of the diff

    @Test("the diff's shape decides it", arguments: [
        (ApprovalQuip.Bucket.deletionHeavy, 30, 400, 6),
        (.countlessFiles, 300, 100, 140),
        (.enormous, 5_400, 200, 40),
        (.huge, 2_500, 100, 30),
        (.big, 900, 150, 12),
        (.veryManyFiles, 300, 120, 60),
        (.manyFiles, 300, 120, 25),
        (.tiny, 20, 8, 2),
        (.singleFile, 300, 120, 1),
    ])
    func diffShape(expected: ApprovalQuip.Bucket, additions: Int, deletions: Int, files: Int) {
        let bucket = ApprovalQuip.bucket(
            for: pr(additions: additions, deletions: deletions, changedFiles: files), now: now
        )
        #expect(bucket == expected)
    }

    /// The boundaries are the whole of the specification, so they are pinned
    /// rather than left to whichever comparison happened to be written.
    @Test("the line thresholds are closed where they claim to be", arguments: [
        (49, ApprovalQuip.Bucket.tiny),
        (50, .generic),
        (999, .generic),
        (1_000, .big),
        (2_000, .big),
        (2_001, .huge),
        (5_000, .huge),
        (5_001, .enormous),
    ])
    func lineThresholds(lines: Int, expected: ApprovalQuip.Bucket) {
        // Split so no deletion-heavy or file-count rule can claim the row first.
        let bucket = ApprovalQuip.bucket(
            for: pr(additions: lines - lines / 4, deletions: lines / 4, changedFiles: 5), now: now
        )
        #expect(bucket == expected)
    }

    @Test("a deletion-heavy diff needs both a ratio and a floor")
    func deletionHeavyNeedsBoth() {
        // 90 deleted against 5 added is the right ratio and too small to remark on.
        #expect(ApprovalQuip.bucket(for: pr(additions: 5, deletions: 90), now: now) != .deletionHeavy)
        #expect(
            ApprovalQuip.bucket(for: pr(additions: 60, deletions: 150), now: now) != .deletionHeavy
        )
        #expect(
            ApprovalQuip.bucket(for: pr(additions: 40, deletions: 150), now: now) == .deletionHeavy
        )
    }

    // MARK: - What the title claims

    @Test("the title is read once the diff has nothing to say", arguments: [
        (":rewind: revert the promotion parser", ApprovalQuip.Bucket.revert),
        (":bug: fix the containment lookup", .fixes),
        (":recycle: refactor the review store", .refactor),
        (":arrow_up: bump swift-testing to 6.2", .dependencies),
        (":white_check_mark: cover the merge gate", .tests),
        (":memo: document the read:org scope", .documentation),
    ])
    func titleClaims(title: String, expected: ApprovalQuip.Bucket) {
        #expect(ApprovalQuip.bucket(for: pr(title: title), now: now) == expected)
    }

    /// Tokenised, not searched: `prefix` contains `fix`, and a remark about
    /// bug-fixing on a PR that renames a prefix would be nonsense.
    @Test("a keyword inside a longer word is not a match", arguments: [
        "rename the prefix on the deployment chips",
        "widen the latest release lookup",
    ])
    func noSubstringMatches(title: String) {
        #expect(ApprovalQuip.bucket(for: pr(title: title), now: now) == .generic)
    }

    // MARK: - The state of the row

    @Test("check state is remarked on when the title claims nothing", arguments: [
        (CheckState.failure, ApprovalQuip.Bucket.checksFailing),
        (.error, .checksFailing),
        (.pending, .checksPending),
        (.expected, .checksPending),
    ])
    func checkState(state: CheckState, expected: ApprovalQuip.Bucket) {
        #expect(ApprovalQuip.bucket(for: pr(checks: state), now: now) == expected)
    }

    /// No CI at all is not a pending build, and must not be remarked on as one.
    @Test("a repository with no checks reads as neither failing nor pending")
    func noChecks() {
        let bucket = ApprovalQuip.bucket(for: pr(checks: nil), now: now)
        #expect(bucket != .checksFailing)
        #expect(bucket != .checksPending)
    }

    @Test("age is remarked on last", arguments: [
        (20.0, ApprovalQuip.Bucket.forgotten),
        (0.01, .fresh),
        (3.0, .generic),
    ])
    func age(daysAgo: Double, expected: ApprovalQuip.Bucket) {
        #expect(ApprovalQuip.bucket(for: pr(openedDaysAgo: daysAgo), now: now) == expected)
    }

    @Test("an already-approved pull request is piled on")
    func piledOn() {
        #expect(ApprovalQuip.bucket(for: pr(reviewDecision: .approved), now: now) == .piledOn)
    }

    /// Precedence, stated as the case that would otherwise be wrong: a 6,000-line
    /// revert with red checks is remarked on for its size, not its title.
    @Test("the diff outranks the title, and the title outranks the checks")
    func precedence() {
        #expect(
            ApprovalQuip.bucket(
                for: pr(title: ":rewind: revert everything", additions: 6_000, checks: .failure),
                now: now
            ) == .enormous
        )
        #expect(
            ApprovalQuip.bucket(for: pr(title: ":bug: fix it", checks: .failure), now: now)
                == .fixes
        )
    }

    // MARK: - The lines themselves

    @Test("every bucket has at least one line, and picks from its own")
    func everyBucketSpeaks() {
        for bucket in ApprovalQuip.Bucket.allCases {
            let lines = ApprovalQuip.lines(for: bucket)
            #expect(lines.isEmpty == false, "\(bucket) has nothing to say")
            #expect(lines.allSatisfy { $0.isEmpty == false })
        }
    }

    @Test("the chosen line comes from the matching bucket")
    func picksFromTheBucket() {
        let request = pr(additions: 10, deletions: 5, changedFiles: 1)
        let text = ApprovalQuip.text(for: request, now: now) { count in count - 1 }

        #expect(ApprovalQuip.lines(for: .tiny).contains(text))
    }

    /// A joke has no business trapping in the middle of an approval, so an index
    /// outside the bucket is clamped rather than trusted.
    @Test("an out-of-range choice still produces a line", arguments: [-3, 0, 99])
    func clampsTheChoice(index: Int) {
        let text = ApprovalQuip.text(for: pr(), now: now) { _ in index }

        #expect(text.isEmpty == false)
        #expect(ApprovalQuip.lines(for: .generic).contains(text))
    }

    /// Every line is posted publicly under the user's name, so none of them may
    /// insult the author or the code — the one property the list must have.
    @Test("no line names the author or calls the work bad")
    func nothingRude() {
        let forbidden = ["stupid", "idiot", "garbage", "rubbish", "awful", "terrible", "you idiot"]
        for bucket in ApprovalQuip.Bucket.allCases {
            for line in ApprovalQuip.lines(for: bucket) {
                let lowered = line.lowercased()
                #expect(
                    forbidden.allSatisfy { !lowered.contains($0) },
                    "\(bucket) line is not fit to post: \(line)"
                )
            }
        }
    }
}
