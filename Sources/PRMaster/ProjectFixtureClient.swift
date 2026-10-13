import Foundation
import PRMasterCore

/// Serves captured GitHub project boards so the board can be inspected without
/// the project scope. Scrubbed by construction: no real node ids, no logins.
struct ProjectFixtureClient: ProjectFetching {

    let path: String

    private struct File: Decodable {
        let projects: [Project]
        let items: [Item]

        struct Project: Decodable {
            let id: String
            let title: String
            let options: [[String]]
        }

        struct Item: Decodable {
            let id: String
            let projectID: String
            let number: Int
            let title: String
            let repo: String
            let isPullRequest: Bool?
            let typeName: String
            let statusOptionID: String?
            let statusChangedDaysAgo: Double?
            let createdHoursAgo: Double?
            let links: [Link]?

            struct Link: Decodable {
                let number: Int
                let title: String
                let state: String
            }
        }
    }

    private func load() throws -> File {
        try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func fetchProjects() async throws -> [GitHubProject] {
        try boards()
    }

    private func boards() throws -> [GitHubProject] {
        try load().projects.enumerated().map { index, project in
            GitHubProject(
                id: project.id, number: index + 1, title: project.title, owner: "acme",
                url: URL(string: "https://github.com/orgs/acme/projects/\(index + 1)")!,
                statusFieldID: "\(project.id)_status",
                options: project.options.map { StatusOption(id: $0[0], name: $0[1]) }
            )
        }
    }

    func fetchProjectItems(projectID: String) async throws -> [ProjectItem] {
        try load().items.filter { $0.projectID == projectID }.map { item in
            ProjectItem(
                id: item.id, projectID: item.projectID, number: item.number, title: item.title,
                url: URL(string: "https://github.com/\(item.repo)/issues/\(item.number)")!,
                repo: item.repo, isPullRequest: item.isPullRequest ?? false, typeName: item.typeName,
                statusOptionID: item.statusOptionID, statusName: nil,
                statusChangedAt: item.statusChangedDaysAgo.map { Date().addingTimeInterval(-$0 * 86_400) },
                createdAt: item.createdHoursAgo.map { Date().addingTimeInterval(-$0 * 3_600) },
                links: (item.links ?? []).map { link in
                    LinkedPullRequest(
                        id: "PR_\(item.repo)_\(link.number)", number: link.number, title: link.title,
                        url: URL(string: "https://github.com/\(item.repo)/pull/\(link.number)")!,
                        repo: item.repo, isPrivate: false, isDraft: false,
                        state: LinkedPullRequestState(rawValue: link.state) ?? .open
                    )
                }
            )
        }
    }

    /// A scratch domain with every fixture board switched on, so a fixture run
    /// never writes fake boards into the real selection.
    func preferences() -> PreferenceStoring {
        let name = "PRMaster.projectFixture"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = UserDefaultsPreferences(defaults: defaults)
        let projects = (try? boards()) ?? []
        preferences.setKnownProjects(projects)
        preferences.setProjectSelection(ProjectSelection(enabled: Set(projects.map(\.id))))
        return preferences
    }
}
