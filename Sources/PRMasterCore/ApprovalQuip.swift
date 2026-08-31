import Foundation

/// The remark posted alongside an approval, chosen from what the row already
/// knows. `ReviewStore` owns whether to post one at all; this owns what it says,
/// and above all which bucket wins when several match.
public enum ApprovalQuip {

    /// Ordered by precedence — the first match wins. What a reviewer would
    /// actually remark on: the shape of the diff first, what the title claims
    /// second, and the state of the row last.
    public enum Bucket: Sendable, CaseIterable {
        case deletionHeavy
        case countlessFiles
        case enormous
        case huge
        case big
        case veryManyFiles
        case manyFiles
        case tiny
        case singleFile
        case revert
        case fixes
        case refactor
        case dependencies
        case tests
        case documentation
        case checksFailing
        case checksPending
        case forgotten
        case fresh
        case piledOn
        case generic
    }

    private static let forgottenAfter: TimeInterval = 14 * 86_400
    private static let freshWithin: TimeInterval = 3_600

    public static func bucket(for request: ReviewRequest, now: Date) -> Bucket {
        let lines = request.additions + request.deletions
        let age = now.timeIntervalSince(request.createdAt)

        if request.deletions >= 100, request.deletions >= 3 * request.additions {
            return .deletionHeavy
        }
        if request.changedFiles > 100 { return .countlessFiles }
        if lines > 5_000 { return .enormous }
        if lines > 2_000 { return .huge }
        if lines >= 1_000 { return .big }
        if request.changedFiles > 50 { return .veryManyFiles }
        if request.changedFiles > 20 { return .manyFiles }
        if lines < 50 { return .tiny }
        if request.changedFiles == 1 { return .singleFile }

        if let claimed = titleBucket(request.title) { return claimed }

        switch request.checks {
        case .failure, .error: return .checksFailing
        case .pending, .expected: return .checksPending
        case .success, nil: break
        }

        if age > forgottenAfter { return .forgotten }
        if age < freshWithin { return .fresh }
        if request.reviewDecision == .approved { return .piledOn }

        return .generic
    }

    /// A line for that pull request. `pick` is injected so the choice can be
    /// pinned in tests; it is handed the number of lines available.
    public static func text(
        for request: ReviewRequest,
        now: Date,
        pick: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> String {
        let available = lines(for: bucket(for: request, now: now))
        // Clamped rather than trusted: the quip is a joke, and a joke has no
        // business trapping in the middle of an approval.
        let index = min(max(pick(available.count), 0), available.count - 1)
        return available[index]
    }

    /// Tokenised on non-alphanumerics, which is what makes a gitmoji shortcode
    /// work as a keyword — `:bug:` and `bug` tokenise alike — and what keeps
    /// `fix` from matching `prefix`. Underscores are kept, or `:arrow_up:` would
    /// come apart into words nobody wrote.
    private static func titleBucket(_ title: String) -> Bucket? {
        let words = Set(
            title.lowercased()
                .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
                .map(String.init)
        )
        return titleKeywords.first { !$0.words.isDisjoint(with: words) }?.bucket
    }

    private static let titleKeywords: [(bucket: Bucket, words: Set<String>)] = [
        (.revert, ["revert", "reverts", "reverting", "reverted", "rewind"]),
        (.fixes, ["fix", "fixes", "fixed", "bug", "bugfix", "hotfix", "patch", "ambulance"]),
        (.refactor, ["refactor", "refactored", "refactoring", "recycle", "cleanup", "simplify"]),
        (.dependencies, [
            "bump", "bumps", "deps", "dependency", "dependencies", "chore",
            "arrow_up", "dependabot", "renovate",
        ]),
        (.tests, ["test", "tests", "testing", "coverage", "white_check_mark"]),
        (.documentation, [
            "doc", "docs", "documentation", "readme", "typo", "memo", "changelog",
        ]),
    ]

    /// Every line this app is willing to post, grouped so a bucket can be read
    /// and edited whole — which is how the list gets reviewed.
    static func lines(for bucket: Bucket) -> [String] {
        switch bucket {
        case .deletionHeavy: return [
            "Approved, enthusiastically. Deleted code is the only code that never breaks. 🔥",
            "Approved. Net negative diff — my favourite genre. 📉",
            "Approved. You took more out than you put in, which is the highest form of engineering. ✂️",
        ]
        case .countlessFiles: return [
            "Approved. A hundred-plus files. Whatever this was refactoring, it lost. 🌍",
            "Approved. I reviewed a representative sample and made peace with the rest. 🙏",
        ]
        case .enormous: return [
            "Approved. Five thousand lines. My scroll wheel has filed a grievance. 🖱️",
            "Approved. This PR has more lines than the service it belongs to had last year. 🏗️",
            "Approved. Reviewing this was a lifestyle, not a task. 🧘",
        ]
        case .huge: return [
            "Approved. I scrolled. I kept scrolling. At some point I made peace with it. 🎢",
            "Approved. Somewhere in these thousands of lines is a bug we'll meet in six months. Good to know it's coming. 🔮",
        ]
        case .big: return [
            "Approved. Four figures of diff and I still clicked the button. Respect. 💪",
            "Approved. This is less a pull request and more a chapter. 📖",
        ]
        case .veryManyFiles: return [
            "Approved. At this file count it's not a change, it's a relocation. 🚚",
        ]
        case .manyFiles: return [
            "Approved. Twenty-odd files touched — hope the blame view is ready. 🗂️",
        ]
        case .tiny: return [
            "Approved. A diff I could actually read in full — thank you for your service. 🔍",
            "Approved. Small, sharp, done. This is the good stuff. 🤏",
            "Approved in under a minute, because you kept it under fifty lines. 📏",
        ]
        case .singleFile: return [
            "Approved. One file, one purpose, zero drama. 🎯",
        ]
        case .revert: return [
            "Approved. Undoing is also engineering. ↩️",
            "Approved. We're all pretending this never happened. 🙈",
        ]
        case .fixes: return [
            "Approved. One bug down, the backlog barely noticed. 🐛",
            "Approved. Fix now, blameless post-mortem later. 🔧",
        ]
        case .refactor: return [
            "Approved. Same behaviour, better vibes. ♻️",
            "Approved. Fewer lines is my favourite kind of feature. ✨",
        ]
        case .dependencies: return [
            "Approved. Another dependency dragged into the present day. 📦",
            "Approved. Robots do the typing, humans click the button. 🤖",
        ]
        case .tests: return [
            "Approved. Tests: the only PR nobody argues about. 🧪",
            "Approved. Future you is grateful, present you is tired. 🟩",
        ]
        case .documentation: return [
            "Approved. The docs thank you on behalf of everyone who never reads them. 📚",
            "Approved. Fixing a typo is the purest form of open source. ✏️",
        ]
        case .checksFailing: return [
            "Approved on the code, not on CI — the red ticks are yours to argue with. 🔴",
            "Approved. CI is having a moment; the diff is fine. 🤷",
        ]
        case .checksPending: return [
            "Approved while CI is still thinking about it. Optimism as a review strategy. ⏳",
            "Approved ahead of the checks — you have my vote, CI has the final word. 🟡",
        ]
        case .forgotten: return [
            "Approved. This PR has been open long enough to develop a personality. Free at last. 🕰️",
            "Sorry for the wait — approved. Your branch has seen things. 👴",
            "Approved. This one's been open so long the style guide changed twice. 📜",
        ]
        case .fresh: return [
            "Approved before the coffee went cold. ☕️",
            "That was quick, wasn't it? Approved. ⚡️",
        ]
        case .piledOn: return [
            "Approved — piling on. Consider this a second signature on the same form. 🖊️",
            "Approved. You had a quorum, now you have a crowd. 👥",
        ]
        case .generic: return [
            "Approved. Shipped straight from the menu bar — no IDE was harmed in the making of this review. 🚀",
            "LGTM. I read it, I understood it, I have chosen to believe in you. ✅",
            "Approved from a menu bar the size of a postage stamp. That's how much I trust this one.",
            "Ship it. The green tick has spoken. 🟢",
        ]
        }
    }
}
