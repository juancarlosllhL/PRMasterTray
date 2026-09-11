import Foundation

enum JiraQueries {
    /// Everything still open, plus whatever reached Done inside the window.
    static func assigned(within window: JiraWindow) -> String {
        guard let done = window.doneQualifier else {
            return "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
        }
        return "assignee = currentUser() AND (statusCategory != Done OR \(done)) "
            + "ORDER BY updated DESC"
    }

    static let issueFields =
        "key,summary,status,issuetype,updated,created,priority,statuscategorychangedate"
    static let pageSize = 100
    /// The old `/rest/api/3/search` answers HTTP 410 with a migration notice.
    static let searchPath = "/rest/api/3/search/jql"
    static let myselfPath = "/rest/api/3/myself"
}

public actor JiraClient {

    private let credentials: JiraCredentials
    private let session: URLSession

    public init(credentials: JiraCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// Every issue assigned to the signed-in user that is not done, plus the
    /// ones finished inside the window.
    public func fetchAssignedIssues(within window: JiraWindow) async throws -> [JiraIssue] {
        try await assignedIssues(within: window)
    }

    public func assignedIssues(within window: JiraWindow = .default) async throws -> [JiraIssue] {
        var collected: [JiraIssue] = []
        var pageToken: String?

        while true {
            let payload = try await searchPage(pageToken: pageToken, window: window)
            collected.append(contentsOf: payload.issues.map(\.domain))

            guard payload.isLast != true, let next = payload.nextPageToken, !next.isEmpty
            else { break }
            pageToken = next
        }

        return collected
    }

    /// Confirms the credentials and answers with who they belong to.
    public func verify() async throws -> String {
        let data = try await get(
            credentials.baseURL.appendingPathComponent(JiraQueries.myselfPath)
        )

        struct Myself: Decodable { let displayName: String? }
        guard let me = try? JSONDecoder().decode(Myself.self, from: data),
              let name = me.displayName
        else {
            throw PRMasterError.decoding("myself response carried no displayName")
        }
        return name
    }

    private func searchPage(pageToken: String?, window: JiraWindow) async throws -> SearchPage {
        var components = URLComponents(
            url: credentials.baseURL.appendingPathComponent(JiraQueries.searchPath),
            resolvingAgainstBaseURL: false
        )!
        var items = [
            URLQueryItem(name: "jql", value: JiraQueries.assigned(within: window)),
            URLQueryItem(name: "fields", value: JiraQueries.issueFields),
            URLQueryItem(name: "maxResults", value: String(JiraQueries.pageSize)),
        ]
        if let pageToken { items.append(URLQueryItem(name: "nextPageToken", value: pageToken)) }
        components.queryItems = items

        return try JiraDecoder.decodeSearch(try await get(components.url!))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PRMaster", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PRMasterError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PRMasterError.decoding("response was not HTTP")
        }

        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw PRMasterError.jiraUnauthorized
        case 429:
            throw PRMasterError.rateLimited(until: Date().addingTimeInterval(60))
        default:
            throw PRMasterError.httpError(status: http.statusCode)
        }
    }
}

struct SearchPage: Decodable {
    let issues: [IssueNode]
    let isLast: Bool?
    let nextPageToken: String?
}

struct IssueNode: Decodable {
    let key: String
    let fields: Fields

    struct Fields: Decodable {
        let summary: String?
        let status: Status?
        let issuetype: IssueType?
        let updated: String?
        let created: String?
        let priority: Priority?
        let statuscategorychangedate: String?

        struct Priority: Decodable {
            let id: String?
        }

        struct Status: Decodable {
            let name: String?
            let statusCategory: Category?

            struct Category: Decodable {
                let key: String?
            }
        }

        struct IssueType: Decodable {
            let name: String?
        }
    }

    var domain: JiraIssue {
        JiraIssue(
            key: key,
            summary: fields.summary ?? "",
            statusName: fields.status?.name ?? "",
            statusCategory: fields.status?.statusCategory?.key
                .flatMap(JiraStatusCategory.init(rawValue:)) ?? .unknown,
            issueType: fields.issuetype?.name ?? "",
            priority: fields.priority?.id.flatMap(JiraPriority.init(id:)) ?? .unset,
            updatedAt: fields.updated.flatMap(JiraDecoder.date(from:)) ?? .distantPast,
            createdAt: fields.created.flatMap(JiraDecoder.date(from:)),
            categoryChangedAt: fields.statuscategorychangedate.flatMap(JiraDecoder.date(from:))
        )
    }
}

public enum JiraDecoder {

    static func decodeSearch(_ data: Data) throws -> SearchPage {
        do {
            return try JSONDecoder().decode(SearchPage.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }
    }

    /// Jira sends `2026-09-10T08:00:00.000+0000`, whose offset has no colon and
    /// which `ISO8601DateFormatter` refuses.
    static func date(from raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter.date(from: raw)
    }
}
