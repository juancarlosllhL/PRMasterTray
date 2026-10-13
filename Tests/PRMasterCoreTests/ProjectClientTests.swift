import Foundation
import Testing
@testable import PRMasterCore

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func bump() { lock.withLock { reads += 1 } }
}

private func makeClient(_ outcomes: [StubOutcome]) -> (GitHubClient, ReadCounter, StubSession) {
    let counter = ReadCounter()
    let stub = StubSession(outcomes: outcomes)
    let provider = TokenProvider(
        paths: ["/fake/gh"],
        fileExists: { _ in true },
        run: { _ in
            counter.bump()
            return TokenProvider.RunResult(stdout: "gho_faketokenvalue", exitCode: 0)
        }
    )
    return (GitHubClient(tokenProvider: provider, session: stub.session), counter, stub)
}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

private let login = StubOutcome.response(status: 200, body: Data(#"{"data":{"viewer":{"login":"octo"}}}"#.utf8))

private func page(hasNext: Bool, cursor: String) -> Data {
    Data("""
    {"data":{"node":{"items":{
      "pageInfo":{"hasNextPage":\(hasNext),"endCursor":"\(cursor)"},"nodes":[]}}}}
    """.utf8)
}

private func variables(of request: RecordedRequest) throws -> [String: Any] {
    let body = try #require(request.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    return json["variables"] as? [String: Any] ?? [:]
}

@Suite("Project client")
struct ProjectClientTests {

    /// `gh auth refresh` may hand out a new token, which this app only reads at launch.
    @Test("a missing scope re-reads the token once, then says how to grant it")
    func scopeRetry() async throws {
        let scope = try fixture("project-scope-error")
        let (client, reads, stub) = makeClient([
            .response(status: 200, body: scope), .response(status: 200, body: scope),
        ])
        await #expect(throws: PRMasterError.projectScopeMissing) {
            try await client.fetchProjects()
        }
        #expect(reads.count == 2)
        #expect(stub.requests.count == 2)
    }

    @Test("a token granted the scope since launch is picked up without a relaunch")
    func scopeGrantedSinceLaunch() async throws {
        let (client, _, stub) = makeClient([
            .response(status: 200, body: try fixture("project-scope-error")),
            .response(status: 200, body: try fixture("projects-discovery")),
        ])
        #expect(try await client.fetchProjects().count == 4)
        #expect(stub.requests.count == 2)
    }

    /// `assignee:<login>` was measured filtering on GitHub's side; `@me` could not be.
    @Test("items are asked for by the viewer's own login, and pages follow the cursor")
    func pagination() async throws {
        let (client, _, stub) = makeClient([
            login,
            .response(status: 200, body: page(hasNext: true, cursor: "c1")),
            .response(status: 200, body: page(hasNext: false, cursor: "c2")),
        ])
        _ = try await client.fetchProjectItems(projectID: "PVT_team")

        #expect(stub.requests.count == 3)
        let first = try variables(of: stub.requests[1])
        let second = try variables(of: stub.requests[2])
        #expect(first["id"] as? String == "PVT_team")
        #expect(first["q"] as? String == "assignee:octo")
        #expect(first["after"] == nil)
        #expect(second["after"] as? String == "c1")
    }

    @Test("the login is asked for once, not once per board")
    func loginCached() async throws {
        let (client, _, stub) = makeClient([
            login,
            .response(status: 200, body: page(hasNext: false, cursor: "a")),
            .response(status: 200, body: page(hasNext: false, cursor: "b")),
        ])
        _ = try await client.fetchProjectItems(projectID: "PVT_1")
        _ = try await client.fetchProjectItems(projectID: "PVT_2")
        #expect(stub.requests.count == 3)
    }

    @Test("a runaway board stops after five pages")
    func pageCap() async throws {
        let outcomes = (0..<8).map { StubOutcome.response(status: 200, body: page(hasNext: true, cursor: "c\($0)")) }
        let (client, _, stub) = makeClient([login] + outcomes)
        _ = try await client.fetchProjectItems(projectID: "PVT_team")
        #expect(stub.requests.count == 6)
    }

    @Test("a move sends every id as a variable, never inside the document")
    func moveVariables() async throws {
        let (client, _, stub) = makeClient([
            .response(status: 200, body: Data(#"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_1"}}}}"#.utf8)),
        ])
        try await client.setStatus(project: "PVT_\"x", item: "PVTI_1", field: "PVTSSF_1", option: "o-done")

        let request = try #require(stub.requests.first)
        let vars = try variables(of: request)
        #expect(vars["project"] as? String == "PVT_\"x")
        #expect(vars["item"] as? String == "PVTI_1")
        #expect(vars["field"] as? String == "PVTSSF_1")
        #expect(vars["option"] as? String == "o-done")
        let raw = try #require(request.body)
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect((body["query"] as? String)?.contains("PVT_") == false)
    }
}
