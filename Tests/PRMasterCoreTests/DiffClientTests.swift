import Foundation
import Testing
@testable import PRMasterCore

private func makeClient(_ outcomes: [StubOutcome]) -> (GitHubClient, StubSession) {
    let stub = StubSession(outcomes: outcomes)
    let provider = TokenProvider(
        paths: ["/fake/gh"],
        fileExists: { _ in true },
        run: { _ in TokenProvider.RunResult(stdout: "gho_faketokenvalue", exitCode: 0) }
    )
    return (GitHubClient(tokenProvider: provider, session: stub.session), stub)
}

private func json(_ string: String) -> StubOutcome {
    .response(status: 200, body: Data(string.utf8))
}

private func meta(
    head: String = "H1", total: Int, viewed: [(String, String)] = [],
    next: String? = nil
) -> StubOutcome {
    let nodes = viewed.map { #"{"path":"\#($0.0)","viewerViewedState":"\#($0.1)"}"# }.joined(separator: ",")
    let cursor = next.map { #""\#($0)""# } ?? "null"
    return json(#"""
    {"data":{"repository":{"pullRequest":{"id":"PR_1","baseRefOid":"B1","headRefOid":"\#(head)","changedFiles":\#(total),
    "files":{"totalCount":\#(total),"pageInfo":{"hasNextPage":\#(next != nil),"endCursor":\#(cursor)},
    "nodes":[\#(nodes)]}}}}}
    """#)
}

private func head(_ oid: String) -> StubOutcome {
    json(#"{"data":{"repository":{"pullRequest":{"headRefOid":"\#(oid)"}}}}"#)
}

private func restFile(_ path: String) -> String {
    #"{"filename":"\#(path)","status":"modified","additions":1,"deletions":1,"changes":2,"patch":"@@ -1 +1 @@\n-a\n+b"}"#
}

private func compare(_ paths: [String]) -> StubOutcome {
    json(#"{"status":"ahead","files":["# + paths.map(restFile).joined(separator: ",") + "]}")
}

private func page(_ paths: [String]) -> StubOutcome {
    json("[" + paths.map(restFile).joined(separator: ",") + "]")
}

private func body(_ request: RecordedRequest) -> String {
    request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

private func variables(_ request: RecordedRequest) throws -> [String: String] {
    let object = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: Any]
    return try #require(object?["variables"] as? [String: String])
}

@Suite("Diff client")
struct DiffClientTests {

    @Test("the diff is read from a compare pinned to the base and head the metadata named")
    func pinnedCompare() async throws {
        let (client, stub) = makeClient([meta(total: 2), compare(["a.swift", "b.swift"])])
        let diff = try await client.loadDiff(repo: "acme/widget", number: 7)

        #expect(diff.pullRequestID == "PR_1")
        #expect(diff.baseOid == "B1")
        #expect(diff.headOid == "H1")
        #expect(diff.files.map(\.path) == ["a.swift", "b.swift"])
        #expect(!diff.isTruncated)
        #expect(stub.requests.count == 2)
        #expect(stub.requests[1].url?.path == "/repos/acme/widget/compare/B1...H1")
    }

    @Test("each file carries the viewed state GitHub holds for it")
    func viewedStates() async throws {
        let (client, stub) = makeClient([
            meta(total: 2, viewed: [("a.swift", "VIEWED"), ("b.swift", "DISMISSED")]),
            compare(["a.swift", "b.swift", "c.swift"]),
        ])
        let diff = try await client.loadDiff(repo: "acme/widget", number: 7)
        #expect(diff.files.map(\.viewed) == [.viewed, .dismissed, .unviewed])
        withExtendedLifetime(stub) {}
    }

    @Test("viewed states past the first hundred files are read page by page")
    func viewedPaging() async throws {
        let (client, stub) = makeClient([
            meta(total: 2, viewed: [("a.swift", "VIEWED")], next: "cursor-1"),
            meta(total: 2, viewed: [("b.swift", "VIEWED")]),
            compare(["a.swift", "b.swift"]),
        ])
        let diff = try await client.loadDiff(repo: "acme/widget", number: 7)
        #expect(diff.files.map(\.viewed) == [.viewed, .viewed])
        #expect(body(stub.requests[1]).contains("cursor-1"))
    }

    @Test("over 300 files the pull request's own file list is paged, a hundred at a time")
    func pagedFallback() async throws {
        let full = (0..<100).map { "f\($0)" }
        let (client, stub) = makeClient([
            meta(total: 301), page(full), page(full.map { $0 + "b" }), page(full.map { $0 + "c" }),
            page(["last"]), head("H1"),
        ])
        let diff = try await client.loadDiff(repo: "acme/widget", number: 7)

        #expect(diff.files.count == 301)
        #expect(diff.headOid == "H1")
        let pages = stub.requests.compactMap(\.url).filter { $0.path.hasSuffix("/pulls/7/files") }
        #expect(pages.map(\.query) == (1...4).map { "per_page=100&page=\($0)" })
    }

    /// The files endpoint follows the branch rather than a commit, so a push in
    /// the middle of paging would stitch two versions into one diff.
    @Test("a head that moved while paging is read again once")
    func movedHeadReloadsOnce() async throws {
        let (client, stub) = makeClient([
            meta(head: "H1", total: 301), page(["a"]), head("H2"),
            meta(head: "H2", total: 301), page(["a", "b"]), head("H2"),
        ])
        let diff = try await client.loadDiff(repo: "acme/widget", number: 7)
        #expect(diff.headOid == "H2")
        #expect(diff.files.map(\.path) == ["a", "b"])
        #expect(stub.requests.count == 6)
    }

    @Test("a head that keeps moving gives up rather than looping")
    func movingHeadGivesUp() async {
        let (client, stub) = makeClient([
            meta(head: "H1", total: 301), page(["a"]), head("H2"),
            meta(head: "H2", total: 301), page(["a"]), head("H3"),
        ])
        await #expect(throws: PRMasterError.diffHeadMoved) {
            try await client.loadDiff(repo: "acme/widget", number: 7)
        }
        withExtendedLifetime(stub) {}
    }

    @Test("over 3000 files the diff says it is incomplete")
    func truncated() async throws {
        let (client, stub) = makeClient([meta(total: 3001), page(["a"]), head("H1")])
        let diff = try await client.loadDiff(repo: "acme/widget", number: 7)
        #expect(diff.isTruncated)
        withExtendedLifetime(stub) {}
    }

    @Test("paging stops at GitHub's 3000-file ceiling")
    func pagingCeiling() async throws {
        let full = (0..<100).map { "f\($0)" }
        let (client, stub) = makeClient([meta(total: 5000)] + Array(repeating: page(full), count: 30) + [head("H1")])
        let diff = try await client.loadDiff(repo: "acme/widget", number: 7)
        #expect(diff.files.count == 3000)
        #expect(stub.requests.count == 32)
    }

    @Test(
        "marking a file sends GitHub's own viewed mutation for that path",
        arguments: [(true, "markFileAsViewed"), (false, "unmarkFileAsViewed")]
    )
    func setViewed(viewed: Bool, mutation: String) async throws {
        let (client, stub) = makeClient([json(#"{"data":{"\#(mutation)":{"clientMutationId":null}}}"#)])
        try await client.setViewed(pullRequestID: "PR_1", path: "src/a.swift", viewed: viewed)
        let sent = body(stub.requests[0])
        #expect(sent.contains(mutation + "(input"))
        #expect(sent.contains("unmark") == !viewed)
        #expect(try variables(stub.requests[0]) == ["id": "PR_1", "path": "src/a.swift"])
    }

    @Test("a refused viewed mutation is an error, not a silent success")
    func setViewedRefused() async {
        let (client, stub) = makeClient([json(#"{"errors":[{"message":"Resource not accessible"}]}"#)])
        await #expect(throws: PRMasterError.self) {
            try await client.setViewed(pullRequestID: "PR_1", path: "a", viewed: true)
        }
        withExtendedLifetime(stub) {}
    }

    @Test("a rate-limited compare reports when to try again")
    func rateLimited() async {
        let (client, stub) = makeClient([meta(total: 1), .response(status: 403, body: Data())])
        await #expect {
            try await client.loadDiff(repo: "acme/widget", number: 7)
        } throws: { error in
            guard case PRMasterError.rateLimited = error else { return false }
            return true
        }
        withExtendedLifetime(stub) {}
    }

    @Test("a pull request GitHub cannot find is a decoding error rather than an empty diff")
    func missingPullRequest() async {
        let (client, stub) = makeClient([json(#"{"data":{"repository":{"pullRequest":null}}}"#)])
        await #expect(throws: PRMasterError.self) {
            try await client.loadDiff(repo: "acme/widget", number: 7)
        }
        withExtendedLifetime(stub) {}
    }
}
