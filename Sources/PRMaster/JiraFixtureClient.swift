import Foundation
import PRMasterCore

/// Serves a captured Jira answer so the pane can be inspected without
/// credentials. Scrubbed by construction: the fixture holds no token, no
/// account id and no real repository names.
struct JiraFixtureClient: JiraIssueFetching, IssueLinkFetching {

    let path: String

    private struct File: Decodable {
        let issues: [Issue]

        struct Issue: Decodable {
            let key: String
            let summary: String
            let statusName: String
            let statusCategory: String
            let issueType: String
            let links: [Link]

            struct Link: Decodable {
                let number: Int
                let title: String
                let repo: String
                let isPrivate: Bool
                let isDraft: Bool
                let state: String
            }
        }
    }

    private func load() throws -> File {
        try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func fetchAssignedIssues() async throws -> [JiraIssue] {
        try load().issues.map { issue in
            JiraIssue(
                key: issue.key,
                summary: issue.summary,
                statusName: issue.statusName,
                statusCategory: JiraStatusCategory(rawValue: issue.statusCategory) ?? .unknown,
                issueType: issue.issueType,
                updatedAt: Date()
            )
        }
    }

    func fetchPullRequests(
        forIssueKeys keys: [String]
    ) async throws -> [String: [LinkedPullRequest]] {
        let file = try load()
        return keys.reduce(into: [:]) { result, key in
            let links = file.issues.first { $0.key == key }?.links ?? []
            result[key] = links.map { link in
                LinkedPullRequest(
                    id: "PR_\(link.repo)_\(link.number)",
                    number: link.number,
                    title: link.title,
                    url: URL(string: "https://github.com/\(link.repo)/pull/\(link.number)")!,
                    repo: link.repo,
                    isPrivate: link.isPrivate,
                    isDraft: link.isDraft,
                    state: LinkedPullRequestState(rawValue: link.state) ?? .open
                )
            }
        }
    }
}
