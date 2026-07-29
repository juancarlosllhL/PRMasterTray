import Foundation
import Testing
@testable import PRMasterCore

@Suite("Emoji shortcodes")
struct EmojiTests {

    @Test("substitutes a known shortcode", arguments: [
        (":sparkles: add feature", "✨ add feature"),
        (":bug: fix the thing", "🐛 fix the thing"),
        (":wrench: tweak config", "🔧 tweak config"),
    ])
    func knownCodes(input: String, expected: String) {
        #expect(EmojiShortcodes.render(input) == expected)
    }

    /// Showing `:foo:` is honest. Guessing, or stripping it, is not.
    @Test("leaves an unknown shortcode exactly as written")
    func unknownCodeSurvives() {
        #expect(EmojiShortcodes.render(":foo: bar") == ":foo: bar")
        #expect(EmojiShortcodes.render("a :not_a_gitmoji: b") == "a :not_a_gitmoji: b")
    }

    @Test("substitutes every shortcode in the title, not just the first")
    func multipleCodes() {
        #expect(EmojiShortcodes.render(":bug: fix :zap: perf") == "🐛 fix ⚡️ perf")
    }

    @Test("handles adjacent shortcodes with no separator")
    func adjacentCodes() {
        #expect(EmojiShortcodes.render(":bug::zap:") == "🐛⚡️")
    }

    /// The colon is load-bearing punctuation in ordinary prose, so the pattern
    /// must not mangle text that merely contains one.
    @Test("leaves colon-bearing prose untouched", arguments: [
        "deploy at 12:30:45 today",
        "TODO: rename this",
        "ratio 3:1",
        "https://github.com/acme/widget/pull/1204",
        "::",
        ":",
    ])
    func colonsInProse(input: String) {
        #expect(EmojiShortcodes.render(input) == input)
    }

    @Test("an empty title renders as empty")
    func emptyTitle() {
        #expect(EmojiShortcodes.render("") == "")
    }

    @Test("a title with no shortcodes is returned unchanged")
    func plainTitle() {
        let title = "Refactor the reports registry"
        #expect(EmojiShortcodes.render(title) == title)
    }

    @Test("substitutes a shortcode that is not at the start")
    func codeInTheMiddle() {
        #expect(EmojiShortcodes.render("release :rocket: now") == "release 🚀 now")
    }

    /// A typo in the table would silently ship a shortcode that never renders.
    @Test("every table entry is a usable key and a non-empty glyph")
    func tableIsWellFormed() {
        for (code, glyph) in EmojiShortcodes.map {
            #expect(!code.isEmpty)
            #expect(!glyph.isEmpty)
            // A key the pattern cannot match is dead weight.
            #expect(EmojiShortcodes.render(":\(code):") == glyph)
        }
    }

    @Test("displayTitle renders the shortcodes in a pull request title")
    func displayTitleRenders() {
        let pr = makePR(title: ":sparkles: actionable notifications")
        #expect(pr.displayTitle == "✨ actionable notifications")
        // The raw title stays untouched: it is what GitHub gave us.
        #expect(pr.title == ":sparkles: actionable notifications")
    }
}

private func makePR(title: String) -> PullRequest {
    PullRequest(
        id: "PR_1",
        number: 1,
        title: title,
        url: URL(string: "https://github.com/acme/widget/pull/1")!,
        repo: "acme/widget",
        isPrivate: false,
        isDraft: false,
        headRefOid: "oid1",
        mergeable: .mergeable,
        mergeState: .clean,
        reviewDecision: nil,
        checks: .success,
        approvals: 0,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}
