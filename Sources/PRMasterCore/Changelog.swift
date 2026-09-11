import Foundation

/// One released version and what it changed, as written in `CHANGELOG.md`.
public struct ChangelogEntry: Sendable, Equatable, Identifiable {
    public let version: String
    public let lines: [String]

    public var id: String { version }

    public init(version: String, lines: [String]) {
        self.version = version
        self.lines = lines
    }
}

/// Reads the bundled changelog.
///
/// Deliberately not a Markdown parser: the file is written to this shape and
/// anything it does not recognise is left out rather than guessed at.
public enum Changelog {

    public static func parse(_ markdown: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var version: String?
        var lines: [String] = []

        func close() {
            if let version { entries.append(ChangelogEntry(version: version, lines: lines)) }
            lines = []
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                close()
                version = self.version(in: line.dropFirst(3))
            } else if line.hasPrefix("- "), version != nil {
                lines.append(String(line.dropFirst(2)))
            }
        }
        close()
        return entries
    }

    private static func version(in heading: Substring) -> String? {
        guard let first = heading.split(whereSeparator: \.isWhitespace).first else { return nil }
        return ReleaseVersion.strip(String(first))
    }

    public static func load(from url: URL?) -> [ChangelogEntry] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }
}

/// Which entries a launch has to show, if any.
public enum WhatsNew {

    public static func entries(
        in changelog: [ChangelogEntry],
        current: String,
        lastSeen: String?,
        isFirstRun: Bool
    ) -> [ChangelogEntry] {
        guard !isFirstRun, lastSeen != current else { return [] }
        guard changelog.contains(where: { $0.version == current }) else { return [] }

        // Nothing recorded means an upgrade from before this existed, which can
        // only speak for the release that introduced it.
        guard let lastSeen else {
            return changelog.filter { $0.version == current }
        }
        return changelog.filter {
            ReleaseVersion.isNewer($0.version, than: lastSeen)
                && !ReleaseVersion.isNewer($0.version, than: current)
        }
    }
}

/// Holds what to show and records that it was shown.
@MainActor
public final class WhatsNewStore {

    public private(set) var entries: [ChangelogEntry]

    private let preferences: PreferenceStoring
    private let currentVersion: String

    public init(
        changelog: [ChangelogEntry],
        currentVersion: String,
        preferences: PreferenceStoring = UserDefaultsPreferences()
    ) {
        self.preferences = preferences
        self.currentVersion = currentVersion
        self.entries = WhatsNew.entries(
            in: changelog,
            current: currentVersion,
            lastSeen: preferences.lastSeenVersion(),
            isFirstRun: !preferences.hasStoredSettings()
        )
    }

    public var hasSomethingToShow: Bool { !entries.isEmpty }

    public func markSeen() {
        preferences.setLastSeenVersion(currentVersion)
        entries = []
    }
}
