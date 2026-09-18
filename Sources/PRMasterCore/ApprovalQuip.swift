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
            "Approved. Fewer lines to read next time, and fewer lines to be wrong. 🧹",
            "Approved. Nothing ages better than code that is no longer there. 🗑️",
        ]
        case .countlessFiles: return [
            "Approved. A hundred-plus files. Whatever this was refactoring, it lost. 🌍",
            "Approved. I reviewed a representative sample and made peace with the rest. 🙏",
            "Approved. I opened the files tab and it opened a support ticket. 📂",
            "Approved. Somewhere in here is the change, and the rest came along for the ride. 🧭",
        ]
        case .enormous: return [
            "Approved. Five thousand lines. My scroll wheel has filed a grievance. 🖱️",
            "Approved. This PR has more lines than the service it belongs to had last year. 🏗️",
            "Approved. Reviewing this was a lifestyle, not a task. 🧘",
            "Approved. GitHub stopped rendering the diff before I stopped reading it. 🫠",
            "Approved. I began this review with a different haircut. 💇",
        ]
        case .huge: return [
            "Approved. I scrolled. I kept scrolling. At some point I made peace with it. 🎢",
            "Approved. Somewhere in these thousands of lines is a bug we'll meet in six months. Good to know it's coming. 🔮",
            "Approved. Two thousand lines is not a diff, it's a commitment. 💍",
            "Approved. I read this in instalments, like a mortgage. 🏦",
        ]
        case .big: return [
            "Approved. Four figures of diff and I still clicked the button. Respect. 💪",
            "Approved. This is less a pull request and more a chapter. 📖",
            "Approved. A thousand lines that never once asked for a second opinion. 🗿",
            "Approved. I'd have asked you to split it, but it had already split my afternoon. 🪓",
        ]
        case .veryManyFiles: return [
            "Approved. At this file count it's not a change, it's a relocation. 🚚",
            "Approved. Fifty-odd files and, I am told, one intention. 🗺️",
            "Approved. Whole directories changed hands today. 🏘️",
            "Approved. The pattern held for the first ten files, so I extended you credit on the rest. 💳",
        ]
        case .manyFiles: return [
            "Approved. Twenty-odd files touched — hope the blame view is ready. 🗂️",
            "Approved. Twenty files that all agree with each other, which is the good kind of sprawl. 🧩",
            "Approved. A find-and-replace with ambitions. 🔁",
            "Approved. Wide but shallow, which is the merciful combination. 🌊",
        ]
        case .tiny: return [
            "Approved. A diff I could actually read in full — thank you for your service. 🔍",
            "Approved. Small, sharp, done. This is the good stuff. 🤏",
            "Approved in under a minute, because you kept it under fifty lines. 📏",
            "Approved. The whole change fit on one screen and I'm still emotional about it. 🖥️",
            "Approved. That's a review, not an expedition. 🥾",
        ]
        case .singleFile: return [
            "Approved. One file, one purpose, zero drama. 🎯",
            "Approved. One file, so there's exactly one place to look when it misbehaves. 🔦",
            "Approved. Nothing to cross-reference, nothing to regret. 📄",
            "Approved. Single file, single reviewer, single click. ☝️",
        ]
        case .revert: return [
            "Approved. Undoing is also engineering. ↩️",
            "Approved. We're all pretending this never happened. 🙈",
            "Approved. Main goes back to how it was, and so do we. ⏪",
            "Approved. Every revert is a lesson with a merge commit attached. 🎓",
        ]
        case .fixes: return [
            "Approved. One bug down, the backlog barely noticed. 🐛",
            "Approved. Fix now, blameless post-mortem later. 🔧",
            "Approved. It was broken, now it isn't, and that's the whole review. 🩹",
            "Approved. The bug had a good run. 🪦",
            "Approved. Well found, and found before a customer found it. 🕵️",
        ]
        case .refactor: return [
            "Approved. Same behaviour, better vibes. ♻️",
            "Approved. Fewer lines is my favourite kind of feature. ✨",
            "Approved. Nothing works differently and everything reads better. 🧼",
            "Approved. The next person to open this file owes you a coffee. ☕️",
            "Approved. Moving the mess into better-shaped boxes still counts. 📦",
        ]
        case .dependencies: return [
            "Approved. Another dependency dragged into the present day. 📦",
            "Approved. Robots do the typing, humans click the button. 🤖",
            "Approved. The lockfile has spoken and I'm not going to argue with it. 🔒",
            "Approved, trusting that the changelog was honest. 🤞",
            "Approved. One version closer to whatever breaks next quarter. 🗓️",
        ]
        case .tests: return [
            "Approved. Tests: the only PR nobody argues about. 🧪",
            "Approved. Future you is grateful, present you is tired. 🟩",
            "Approved. Coverage went up and nobody had to be talked into it. 📈",
            "Approved. Writing the test after the bug is still writing the test. 🧾",
            "Approved. Green today, and a tripwire for whoever refactors this next. 🪤",
        ]
        case .documentation: return [
            "Approved. The docs thank you on behalf of everyone who never reads them. 📚",
            "Approved. Fixing a typo is the purest form of open source. ✏️",
            "Approved. Someone reading this at two in the morning will feel less alone. 🌙",
            "Approved. The README now describes the software we actually have. 🗺️",
            "Approved. No code changed, so nothing can break. My favourite guarantee. 🛡️",
        ]
        case .checksFailing: return [
            "Approved on the code, not on CI — the red ticks are yours to argue with. 🔴",
            "Approved. CI is having a moment; the diff is fine. 🤷",
            "Approved. The logic is sound, the pipeline is a separate negotiation. 🤝",
            "Approved. I read the diff, not the build log. One of us has to stay hopeful. 🎈",
        ]
        case .checksPending: return [
            "Approved while CI is still thinking about it. Optimism as a review strategy. ⏳",
            "Approved ahead of the checks — you have my vote, CI has the final word. 🟡",
            "Approved. I got here before the pipeline did, which rarely happens. 🏁",
            "Approved. The spinner and I have an understanding. 🔄",
        ]
        case .forgotten: return [
            "Approved. This PR has been open long enough to develop a personality. Free at last. 🕰️",
            "Sorry for the wait — approved. Your branch has seen things. 👴",
            "Approved. This one's been open so long the style guide changed twice. 📜",
            "Approved. Two weeks in the queue and it still merges cleanly. Remarkable. 🏺",
            "Approved. Rebasing it is now the hard part, and that one's on you. 🧗",
        ]
        case .fresh: return [
            "Approved before the coffee went cold. ☕️",
            "That was quick, wasn't it? Approved. ⚡️",
            "Approved. The notification hadn't finished vibrating. 📳",
            "Opened and approved inside the hour. Savour it, this won't happen again. 🍀",
        ]
        case .piledOn: return [
            "Approved — piling on. Consider this a second signature on the same form. 🖊️",
            "Approved. You had a quorum, now you have a crowd. 👥",
            "Approved. Already green, but I wanted to be in the photo. 📸",
            "Approved. Redundant, agreeable, on the record. 🗳️",
        ]
        case .generic: return [
            "Approved. Shipped straight from the menu bar — no IDE was harmed in the making of this review. 🚀",
            "LGTM. I read it, I understood it, I have chosen to believe in you. ✅",
            "Approved from a menu bar the size of a postage stamp. That's how much I trust this one.",
            "Ship it. The green tick has spoken. 🟢",
            "Approved. Nothing to remark on, which is its own kind of compliment. 🫡",
            "Approved. Read, considered, waved through. 👌",
        ]
        }
    }
}
