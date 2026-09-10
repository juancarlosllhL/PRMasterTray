import Foundation
import Testing
@testable import PRMasterCore

private func credentials() throws -> JiraCredentials {
    try JiraCredentials(
        baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "tok"
    )
}

private func page(_ keys: [String], isLast: Bool, token: String? = nil) -> String {
    let issues = keys.map {
        """
        {"id":"1","key":"\($0)","fields":{
          "summary":"a summary",
          "status":{"name":"On Hold","statusCategory":{"key":"new","name":"To Do"}},
          "issuetype":{"name":"Task"},
          "updated":"2026-09-10T08:00:00.000+0000"}}
        """
    }.joined(separator: ",")
    let next = token.map { #","nextPageToken":"\#($0)""# } ?? ""
    return #"{"issues":[\#(issues)],"isLast":\#(isLast)\#(next)}"#
}

@Suite("Jira date parsing")
struct JiraDateTests {

    /// The exact shape the live site sends. `ISO8601DateFormatter` refuses it,
    /// because the offset carries no colon — and a silent parse failure would
    /// date every issue to distantPast and scramble the ordering.
    @Test("the real wire format parses", arguments: [
        "2026-09-10T14:38:58.066+0200",
        "2026-09-10T11:34:17.434+0200",
        "2026-09-10T08:00:00.000+0000",
        "2026-01-02T03:04:05.678-0500",
    ])
    func realFormatParses(raw: String) {
        #expect(JiraDecoder.date(from: raw) != nil)
    }

    @Test("the offset is honoured rather than ignored")
    func offsetIsHonoured() throws {
        let utc = try #require(JiraDecoder.date(from: "2026-09-10T12:00:00.000+0000"))
        let plusTwo = try #require(JiraDecoder.date(from: "2026-09-10T14:00:00.000+0200"))
        #expect(utc == plusTwo)
    }

    @Test("nonsense yields nil rather than a wrong date", arguments: [
        "", "not a date", "2026-09-10", "2026-09-10T14:38:58Z",
    ])
    func nonsenseIsNil(raw: String) {
        #expect(JiraDecoder.date(from: raw) == nil)
    }
}

@Suite("JiraClient")
struct JiraClientTests {

    @Test("the request carries Basic auth and the JQL")
    func requestShape() async throws {
        let stub = StubSession(outcomes: [.response(status: 200, body: Data(page(["ACME-1"], isLast: true).utf8))])
        let client = JiraClient(credentials: try credentials(), session: stub.session)

        _ = try await client.assignedIssues()

        let request = try #require(stub.requests.first)
        let url = try #require(request.url)
        #expect(url.absoluteString.contains("/rest/api/3/search/jql"))
        #expect(request.headers["Authorization"]?.hasPrefix("Basic ") == true)

        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let jql = try #require(items.first { $0.name == "jql" }?.value)
        #expect(jql.contains("assignee = currentUser()"))
        #expect(jql.contains("statusCategory != Done"))
        #expect(items.first { $0.name == "fields" }?.value?.contains("statusCategory") == false)
    }

    /// A space in a raw URL would make the request malformed, so the JQL has to
    /// go through URLQueryItem encoding.
    @Test("the JQL is percent-encoded")
    func jqlIsEncoded() async throws {
        let stub = StubSession(outcomes: [.response(status: 200, body: Data(page([], isLast: true).utf8))])
        _ = try await JiraClient(credentials: try credentials(), session: stub.session)
            .assignedIssues()

        let url = try #require(stub.requests.first?.url)
        #expect(!url.absoluteString.contains(" "))
    }

    @Test("issues decode with their category")
    func issuesDecode() async throws {
        let stub = StubSession(outcomes: [.response(status: 200, body: Data(page(["ACME-1"], isLast: true).utf8))])
        let issues = try await JiraClient(credentials: try credentials(), session: stub.session)
            .assignedIssues()

        #expect(issues.count == 1)
        #expect(issues.first?.key == "ACME-1")
        #expect(issues.first?.statusName == "On Hold")
        #expect(issues.first?.statusCategory == .toDo)
        #expect(issues.first?.issueType == "Task")
    }

    /// Verified live: the real account fits on one page, so paging would go
    /// untested without this.
    @Test("nextPageToken is followed until isLast")
    func pagingIsFollowed() async throws {
        let stub = StubSession(outcomes: [
            .response(status: 200, body: Data(page(["ACME-1"], isLast: false, token: "abc").utf8)),
            .response(status: 200, body: Data(page(["ACME-2"], isLast: true).utf8)),
        ])
        let issues = try await JiraClient(credentials: try credentials(), session: stub.session)
            .assignedIssues()

        #expect(issues.map(\.key) == ["ACME-1", "ACME-2"])
        #expect(stub.requests.count == 2)

        let secondURL = try #require(stub.requests[1].url)
        let second = try #require(
            URLComponents(url: secondURL, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(second.first { $0.name == "nextPageToken" }?.value == "abc")
    }

    /// A malformed or missing token must not spin forever on the same page.
    @Test("paging stops when isLast is false but no token is given")
    func pagingStopsWithoutToken() async throws {
        let stub = StubSession(outcomes: [
            .response(status: 200, body: Data(page(["ACME-1"], isLast: false).utf8)),
        ])
        let issues = try await JiraClient(credentials: try credentials(), session: stub.session)
            .assignedIssues()

        #expect(issues.count == 1)
        #expect(stub.requests.count == 1)
    }

    @Test("statuses map to PRMasterError", arguments: [
        (401, PRMasterError.jiraUnauthorized),
        (403, PRMasterError.jiraUnauthorized),
        (410, PRMasterError.httpError(status: 410)),
        (500, PRMasterError.httpError(status: 500)),
    ])
    func statusMapping(status: Int, expected: PRMasterError) async throws {
        let stub = StubSession(outcomes: [.response(status: status, body: Data("{}".utf8))])
        let client = JiraClient(credentials: try credentials(), session: stub.session)

        await #expect(throws: expected) { try await client.assignedIssues() }
    }

    @Test("verify returns the display name")
    func verifyNamesTheUser() async throws {
        let body = #"{"accountId":"1","displayName":"Ada Lovelace","emailAddress":"a@b.com"}"#
        let stub = StubSession(outcomes: [.response(status: 200, body: Data(body.utf8))])
        let name = try await JiraClient(credentials: try credentials(), session: stub.session)
            .verify()

        #expect(name == "Ada Lovelace")
        #expect(stub.requests.first?.url?.absoluteString.contains("/rest/api/3/myself") == true)
    }

    /// Verified live: a bad token, a wrong email and outright garbage all
    /// answer 401 identically, so this is the only signal the form gets.
    @Test("verify maps 401 to the pair-blaming error")
    func verifyUnauthorized() async throws {
        let stub = StubSession(outcomes: [.response(status: 401, body: Data("nope".utf8))])
        let client = JiraClient(credentials: try credentials(), session: stub.session)

        await #expect(throws: PRMasterError.jiraUnauthorized) { try await client.verify() }
    }
}
