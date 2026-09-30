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

    static func issuePath(_ key: String) -> String { "/rest/api/3/issue/\(key)" }
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

    public func transitions(for key: String) async throws -> (JiraStatus, [JiraTransition]) {
        var components = URLComponents(
            url: credentials.baseURL.appendingPathComponent(JiraQueries.issuePath(try Self.checked(key))),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "status"),
            URLQueryItem(name: "expand", value: "transitions.fields"),
        ]
        let data = try await send(request(for: components.url!), refusing: true)
        do {
            return try JSONDecoder().decode(TransitionsPage.self, from: data).domain()
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }
    }

    public func perform(
        _ transition: JiraTransition, on key: String, values: [String: String]
    ) async throws {
        let url = credentials.baseURL
            .appendingPathComponent(JiraQueries.issuePath(try Self.checked(key)) + "/transitions")
        var request = request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["transition": ["id": transition.id]]
        let fields = transition.fields.reduce(into: [String: Any]()) { fields, field in
            if let value = values[field.id] { fields[field.id] = JiraField.encode(value, as: field.kind) }
        }
        if !fields.isEmpty { body["fields"] = fields }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request, refusing: true)
    }

    /// The key lands in a URL path, and a dropped string can come from any app.
    static func checked(_ key: String) throws -> String {
        guard key.wholeMatch(of: /[A-Z][A-Z0-9_]*-[0-9]+/) != nil else {
            throw PRMasterError.jiraMoveRefused("“\(key)” is not a Jira issue key.")
        }
        return key
    }

    private func get(_ url: URL) async throws -> Data {
        try await send(request(for: url))
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PRMaster", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// `refusing` is for moves: there a 403 means no permission to transition,
    /// not a bad token, and Jira explains every 4xx in the body.
    private func send(_ request: URLRequest, refusing: Bool = false) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PRMasterError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PRMasterError.decoding("response was not HTTP")
        }

        if refusing, [400, 403, 404, 409].contains(http.statusCode) {
            throw PRMasterError.jiraMoveRefused(JiraDecoder.refusal(data, status: http.statusCode))
        }

        switch http.statusCode {
        case 200, 204:
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
            let id: String?
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
            statusID: fields.status?.id,
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

struct TransitionsPage: Decodable {
    let fields: Fields
    let transitions: [Node]

    struct Fields: Decodable { let status: IssueNode.Fields.Status? }

    struct Node: Decodable {
        let id: String
        let isGlobal: Bool?
        let to: IssueNode.Fields.Status
        let fields: [String: Field]?

        struct Field: Decodable {
            let required: Bool?
            let name: String?
            let schema: Schema?
            let allowedValues: [Allowed]?

            struct Schema: Decodable { let custom: String? }
            struct Allowed: Decodable { let value: String?; let name: String? }

            var kind: JiraField.Kind? {
                switch schema?.custom?.split(separator: ":").last {
                case "select", "radiobuttons":
                    return .option((allowedValues ?? []).compactMap { $0.value ?? $0.name })
                case "textarea":  return .richText
                case "textfield": return .text
                default:          return nil
                }
            }
        }
    }

    func domain() throws -> (JiraStatus, [JiraTransition]) {
        guard let status = fields.status, status.name?.isEmpty == false else {
            throw PRMasterError.decoding("transitions response carried no status")
        }
        let transitions = transitions.map { node in
            let screen = (node.fields ?? [:]).sorted { $0.key < $1.key }
            return JiraTransition(
                id: node.id,
                to: Self.status(node.to),
                isGlobal: node.isGlobal ?? false,
                needsInput: screen.contains { $0.value.required == true && $0.value.kind == nil },
                fields: screen.compactMap { id, field in
                    field.kind.map { JiraField(id: id, name: field.name ?? id, kind: $0) }
                }
            )
        }
        return (Self.status(status), transitions)
    }

    private static func status(_ raw: IssueNode.Fields.Status) -> JiraStatus {
        JiraStatus(
            name: raw.name ?? "",
            category: raw.statusCategory?.key.flatMap(JiraStatusCategory.init(rawValue:)) ?? .unknown,
            id: raw.id
        )
    }
}

public enum JiraDecoder {

    /// Jira puts general reasons in `errorMessages` and per-field ones in `errors`.
    static func refusal(_ data: Data, status: Int) -> String {
        struct Body: Decodable {
            let errorMessages: [String]?
            let errors: [String: String]?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let reasons = (body?.errorMessages ?? [])
            + (body?.errors ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        return reasons.isEmpty ? "Jira answered HTTP \(status)." : reasons.joined(separator: " ")
    }

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
