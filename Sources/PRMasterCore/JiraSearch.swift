import Foundation

public enum JiraSearch {

    /// Words rather than a phrase, so "extract logic" finds an issue whose
    /// summary separates the two.
    public static func matches(_ issue: JiraIssue, query: String) -> Bool {
        let terms = words(in: query)
        guard !terms.isEmpty else { return true }
        let haystack = folded("\(issue.key) \(issue.summary)")
        return terms.allSatisfy(haystack.contains)
    }

    private static func words(in query: String) -> [String] {
        folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension JiraGroups {
    public func matching(_ query: String) -> JiraGroups {
        JiraGroups(
            toDo: toDo.filter { JiraSearch.matches($0, query: query) },
            inProgress: inProgress.filter { JiraSearch.matches($0, query: query) },
            testing: testing.filter { JiraSearch.matches($0, query: query) },
            done: done.filter { JiraSearch.matches($0, query: query) }
        )
    }
}
