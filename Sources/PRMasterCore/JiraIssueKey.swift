import Foundation

public enum JiraIssueKey {
    /// Lansweeper's Jira projects, plus POC. A known list rather than any
    /// `ABC-123`, because titles also carry UTF-8 and RFC-002.
    public static let projects: Set<String> = [
        "AAFSP", "ACME", "CDKC", "CHSP", "DATA", "ENSE", "EPI", "ETEO", "FING",
        "GROW", "INDIRECT", "ITD", "ITP", "LAN", "LS", "OI", "OPSLI", "PI",
        "PLAT", "POC", "PRODUCT", "REL", "SC", "SKILLS", "TS", "UXT",
    ]

    public static func first(in title: String) -> String? {
        let pattern = /\b([A-Z][A-Z0-9]*)-([1-9][0-9]*)\b/
        return title.matches(of: pattern)
            .first { projects.contains(String($0.output.1)) }
            .map { String($0.output.0) }
    }

    public static func browseURL(_ key: String, on base: URL) -> URL {
        base.appendingPathComponent("browse/\(key)")
    }
}
