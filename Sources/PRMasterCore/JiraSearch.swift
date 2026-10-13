import Foundation

/// Words rather than a phrase, so "extract logic" finds a card whose title
/// separates the two.
public enum BoardSearch {

    public static func terms(in query: String) -> [String] {
        folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func matches(_ text: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = folded(text)
        return terms.allSatisfy(haystack.contains)
    }

    public static func matches(_ card: BoardCard, terms: [String]) -> Bool {
        matches("\(card.reference) \(card.pairedReference ?? "") \(card.title)", terms: terms)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

public enum JiraSearch {
    public static func matches(_ issue: JiraIssue, query: String) -> Bool {
        BoardSearch.matches("\(issue.key) \(issue.summary)", terms: BoardSearch.terms(in: query))
    }
}
