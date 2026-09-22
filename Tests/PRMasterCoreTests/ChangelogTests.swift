import Foundation
import Testing
@testable import PRMasterCore

private let sample = """
# Changelog

## 0.11.0 — 2026-09-11

- A Testing section in the Jira pane.
- Titles can be shown without their emoji.

## 0.10.1

- Merged rows no longer sit on "building" after they have shipped.

## 0.10.0

- Approving a pull request can leave a remark.
"""

@Suite("Changelog")
struct ChangelogTests {

    @Test("each heading becomes an entry, newest first")
    func parsesEntries() {
        let entries = Changelog.parse(sample)
        #expect(entries.map(\.version) == ["0.11.0", "0.10.1", "0.10.0"])
        #expect(entries[0].lines.count == 2)
        #expect(entries[0].lines[0] == "A Testing section in the Jira pane.")
        #expect(entries[1].lines == ["Merged rows no longer sit on \"building\" after they have shipped."])
    }

    /// The date is for whoever reads the file, and the tag's `v` is how git
    /// spells it. Neither is part of the version the app compares.
    @Test("a heading is read down to its version alone", arguments: [
        ("## 0.11.0", "0.11.0"),
        ("## v0.11.0", "0.11.0"),
        ("## 0.11.0 — 2026-09-11", "0.11.0"),
        ("##   0.11.0  ", "0.11.0"),
    ])
    func headingForms(heading: String, version: String) {
        #expect(Changelog.parse("\(heading)\n\n- a line").first?.version == version)
    }

    @Test("prose between the bullets is left out")
    func onlyBullets() {
        let entries = Changelog.parse("""
        ## 1.0.0

        This release is mostly about the pane.

        - The one line that matters.
        """)
        #expect(entries.first?.lines == ["The one line that matters."])
    }

    @Test("an image line becomes the entry's picture, not a bullet")
    func parsesImage() {
        let entries = Changelog.parse("""
        ## 0.12.0

        ![A board, a column per group](board.png)

        - A line that is still a line.
        """)

        #expect(entries.first?.image == "board.png")
        #expect(entries.first?.lines == ["A line that is still a line."])
    }

    @Test("an entry with no image has none")
    func noImage() {
        #expect(Changelog.parse(sample).allSatisfy { $0.image == nil })
    }

    /// The window has room for one picture, and the first is the one written
    /// closest to the heading.
    @Test("the first image wins when several are written")
    func firstImageWins() {
        let markdown = "## 0.12.0\n\n![one](a.png)\n\n![two](b.png)\n\n- a line"
        #expect(Changelog.parse(markdown).first?.image == "a.png")
    }

    @Test("a malformed image line is left out entirely", arguments: [
        "![no closing paren](a.png",
        "![](   )",
        "!not an image at all",
    ])
    func malformedImage(line: String) {
        let entries = Changelog.parse("## 0.12.0\n\n\(line)\n\n- a line")
        #expect(entries.first?.image == nil)
        #expect(entries.first?.lines == ["a line"])
    }

    /// A path out of the bundle would be a way to point the window at any file
    /// on disk, so only a bare file name is accepted.
    @Test("a path is refused, only a bare file name is taken", arguments: [
        "![x](../../etc/passwd)",
        "![x](/etc/passwd)",
        "![x](sub/dir/board.png)",
    ])
    func refusesPaths(line: String) {
        #expect(Changelog.parse("## 0.12.0\n\n\(line)\n\n- a line").first?.image == nil)
    }

    @Test("a file with no headings yields nothing", arguments: ["", "# Changelog", "- orphan"])
    func nothingToParse(text: String) {
        #expect(Changelog.parse(text).isEmpty)
    }
}

@Suite("WhatsNew")
struct WhatsNewTests {

    private let changelog = Changelog.parse(sample)

    private func shown(lastSeen: String?, current: String = "0.11.0", first: Bool = false) -> [String] {
        WhatsNew.entries(
            in: changelog, current: current, lastSeen: lastSeen, isFirstRun: first
        ).map(\.version)
    }

    /// Somebody who has just installed the app has not missed anything, and a
    /// changelog is a poor first impression.
    @Test("a first run shows nothing")
    func firstRunIsSilent() {
        #expect(shown(lastSeen: nil, first: true).isEmpty)
    }

    @Test("the same version twice shows nothing")
    func alreadySeen() {
        #expect(shown(lastSeen: "0.11.0").isEmpty)
    }

    /// The version before this feature existed recorded nothing, so the upgrade
    /// that introduces it can only speak for itself.
    @Test("no recorded version shows the current one alone")
    func nothingRecorded() {
        #expect(shown(lastSeen: nil) == ["0.11.0"])
    }

    @Test("skipping releases shows every one that was missed")
    func catchesUp() {
        #expect(shown(lastSeen: "0.10.0") == ["0.11.0", "0.10.1"])
    }

    /// A downgrade, or a version the changelog never mentions.
    @Test("nothing is claimed for a version that is not in the file")
    func unknownCurrentVersion() {
        #expect(shown(lastSeen: "0.10.0", current: "0.9.0").isEmpty)
        #expect(shown(lastSeen: "0.10.0", current: "0.12.0").isEmpty)
    }

    /// An entry written ahead of the release must not be shown by the version
    /// that precedes it.
    @Test("an entry newer than the running app is held back")
    func futureEntriesHeldBack() {
        #expect(shown(lastSeen: "0.10.0", current: "0.10.1") == ["0.10.1"])
    }
}

@Suite("WhatsNewStore")
@MainActor
struct WhatsNewStoreTests {

    private func store(
        lastSeen: String? = "0.10.0",
        used: Bool = true
    ) -> (WhatsNewStore, MemoryPreferences) {
        let preferences = MemoryPreferences()
        if let lastSeen { preferences.setLastSeenVersion(lastSeen) }
        if used { preferences.markUsed() }
        return (
            WhatsNewStore(
                changelog: Changelog.parse(sample),
                currentVersion: "0.11.0",
                preferences: preferences
            ),
            preferences
        )
    }

    @Test("an upgrade has something to say")
    func upgradeHasEntries() {
        let (whatsNew, _) = store()
        #expect(whatsNew.entries.map(\.version) == ["0.11.0", "0.10.1"])
    }

    /// Recorded on dismissal rather than on display, so a crash or a force quit
    /// does not swallow the one showing of it.
    @Test("dismissing records the version and empties the list")
    func dismissRecords() {
        let (whatsNew, preferences) = store()
        whatsNew.markSeen()

        #expect(preferences.lastSeenVersion() == "0.11.0")
        #expect(whatsNew.entries.isEmpty)
    }

    @Test("an install that has never stored anything is a first run")
    func freshInstallIsSilent() {
        let (whatsNew, preferences) = store(lastSeen: nil, used: false)
        #expect(whatsNew.entries.isEmpty)
        #expect(preferences.lastSeenVersion() == nil)
    }

    @Test("an install that has been used shows the current release")
    func upgradeFromBeforeTheFeature() {
        let (whatsNew, _) = store(lastSeen: nil, used: true)
        #expect(whatsNew.entries.map(\.version) == ["0.11.0"])
    }
}
