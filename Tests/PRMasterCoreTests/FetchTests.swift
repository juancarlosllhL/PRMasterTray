import Foundation
import Testing
@testable import PRMasterCore

/// Counts how often the token was read, so the 401 retry can be pinned down.
private final class TokenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func bump() { lock.withLock { _count += 1 } }
}

private func makeClient(_ outcomes: [StubOutcome], token: String = "gho_faketokenvalue")
    -> (client: GitHubClient, tokenReads: TokenCounter, stub: StubSession) {
    let counter = TokenCounter()
    let stub = StubSession(outcomes: outcomes)
    let provider = TokenProvider(
        paths: ["/fake/gh"],
        fileExists: { _ in true },
        run: { _ in
            counter.bump()
            return TokenProvider.RunResult(stdout: token, exitCode: 0)
        }
    )
    return (GitHubClient(tokenProvider: provider, session: stub.session), counter, stub)
}

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

@Suite
struct FetchTests {

    // MARK: request shape

    @Test("posts the search query to the GraphQL endpoint with a bearer token")
    func requestShape() async throws {
        let ctx = makeClient([.response(status: 200, body: try fixtureData("search-response"))])
        _ = try await ctx.client.fetchMyPullRequests()

        let request = try #require(ctx.stub.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")
        #expect(request.headers["Authorization"] == "bearer gho_faketokenvalue")

        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body.contains("is:pr is:open author:@me"))
        #expect(body.contains("archived:false"))
        #expect(body.contains("sort:updated-desc"))
        #expect(body.contains("first: 50"))
        // Every field the readiness rule depends on must be requested.
        #expect(body.contains("mergeStateStatus"))
        #expect(body.contains("statusCheckRollup"))
        #expect(body.contains("headRefOid"))
    }

    @Test("maps a successful response onto domain models")
    func decodesResponse() async throws {
        let ctx = makeClient([.response(status: 200, body: try fixtureData("search-response"))])
        let prs = try await ctx.client.fetchMyPullRequests()
        #expect(prs.open.count == 4)
        #expect(prs.open.first?.repo == "acme/widget-service")
    }

    // MARK: failure handling

    /// GitHub reports SSO failures as HTTP 200 with an errors array, so the
    /// status code alone would let them through as an empty list.
    @Test("surfaces errors carried by a 200 response")
    func errorsOnSuccessStatus() async throws {
        let ctx = makeClient([.response(status: 200, body: try fixtureData("graphql-errors"))])
        await #expect(throws: PRMasterError.self) {
            _ = try await ctx.client.fetchMyPullRequests()
        }
    }

    @Test("maps transport failures to network")
    func networkFailure() async throws {
        let ctx = makeClient([.failure(URLError(.notConnectedToInternet))])
        do {
            _ = try await ctx.client.fetchMyPullRequests()
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .network(let urlError) = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
            #expect(urlError.code == .notConnectedToInternet)
        }
    }

    /// The failure a user actually reported: a proxy answered for
    /// api.github.com with an HTML page, and the popover filled with the JSON
    /// decoder's account of it.
    @Test("an HTML body on a 200 never reaches the decoder", arguments: [
        "<!DOCTYPE html><html><body>Access denied</body></html>",
        "  \n<html>Sign in to the network</html>",
        "",
    ])
    func htmlBody(body: String) async throws {
        let ctx = makeClient([.response(status: 200, body: Data(body.utf8))])
        await #expect(throws: PRMasterError.notJSON) {
            _ = try await ctx.client.fetchMyPullRequests()
        }
    }

    @Test("maps an unusable status to httpError", arguments: [403, 502, 503])
    func unusableStatus(status: Int) async throws {
        let ctx = makeClient([.response(status: status, body: Data("<html>nope</html>".utf8))])
        await #expect(throws: PRMasterError.httpError(status: status)) {
            _ = try await ctx.client.fetchMyPullRequests()
        }
    }

    @Test("maps a 429 to rateLimited")
    func rateLimited() async throws {
        let ctx = makeClient([.response(status: 429, body: Data("{}".utf8))])
        do {
            _ = try await ctx.client.fetchMyPullRequests()
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .rateLimited = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
        }
    }

    // MARK: the 401 retry

    /// gh rotates tokens, so a 401 is often stale-credential rather than
    /// revoked-access. One silent re-read is worth it; a loop is not.
    @Test("a 401 retries once with a freshly read token, then gives up")
    func retriesOnceThenFails() async throws {
        let ctx = makeClient([
            .response(status: 401, body: Data("{}".utf8)),
            .response(status: 401, body: Data("{}".utf8)),
        ])

        await #expect(throws: PRMasterError.unauthorized) {
            _ = try await ctx.client.fetchMyPullRequests()
        }
        #expect(ctx.stub.requests.count == 2, "should retry exactly once")
        #expect(ctx.tokenReads.count == 2, "should re-read the token for the retry")
    }

    @Test("a 401 followed by success returns the data")
    func retrySucceeds() async throws {
        let ctx = makeClient([
            .response(status: 401, body: Data("{}".utf8)),
            .response(status: 200, body: try fixtureData("search-response")),
        ])
        let prs = try await ctx.client.fetchMyPullRequests()
        #expect(prs.open.count == 4)
        #expect(ctx.stub.requests.count == 2)
        #expect(ctx.tokenReads.count == 2)
    }

    @Test("a successful call reads the token only once")
    func cachesToken() async throws {
        let ctx = makeClient([
            .response(status: 200, body: try fixtureData("search-response")),
            .response(status: 200, body: try fixtureData("search-response")),
        ])
        _ = try await ctx.client.fetchMyPullRequests()
        _ = try await ctx.client.fetchMyPullRequests()
        #expect(ctx.tokenReads.count == 1, "token should be cached across calls")
    }

    // MARK: both halves in one request

    @Test("the search asks for the open and merged halves together")
    func asksForBothHalves() async throws {
        let ctx = makeClient([.response(status: 200, body: try fixtureData("search-response"))])
        _ = try await ctx.client.fetchMyPullRequests()

        let body = String(decoding: try #require(ctx.stub.requests.first?.body), as: UTF8.self)
        #expect(body.contains("is:pr is:open author:@me"))
        #expect(body.contains("is:pr is:merged author:@me"))
        // The window rides as a bound variable, never pasted into the document.
        #expect(body.contains("mergedQuery"))
        #expect(body.contains("merged:>"))
    }

    /// Both halves come out of one body, which is the point of asking for them
    /// together: they can never describe different moments.
    @Test("one response yields both the open and the merged pull requests")
    func parsesBothHalves() async throws {
        let ctx = makeClient([.response(status: 200, body: try fixtureData("merged-search"))])
        let snapshot = try await ctx.client.fetchMyPullRequests()

        #expect(snapshot.open.isEmpty)
        #expect(snapshot.merged.count == 4)
        #expect(snapshot.merged.first?.repo == "acme/widget-service")
        #expect(snapshot.merged.first?.contexts.isEmpty == false)
        #expect(ctx.stub.requests.count == 1, "both halves ride in one request")
    }

    // MARK: releases

    /// Nothing merged means nothing to look up, and a request that asks about
    /// no repositories is a rate-limit point spent on nothing.
    @Test("fetching releases for no repositories makes no request at all")
    func noReleasesNoRequest() async throws {
        let ctx = makeClient([])
        let releases = try await ctx.client.fetchReleases(repoIDs: [])
        #expect(releases.isEmpty)
        #expect(ctx.stub.requests.isEmpty)
    }

    @Test("releases come back keyed by repository node id")
    func decodesReleases() async throws {
        let body = Data("""
        {"data":{"nodes":[
          {"id":"R_1","releases":{"nodes":[
            {"tagName":"v1.226.0","url":"https://github.com/acme/widget-service/releases/tag/v1.226.0",
             "createdAt":"2026-08-14T07:22:45Z","isDraft":false,
             "tagCommit":{"oid":"5e0c08f"}}
          ]}}
        ]}}
        """.utf8)
        let ctx = makeClient([.response(status: 200, body: body)])

        let releases = try await ctx.client.fetchReleases(repoIDs: ["R_1"])
        #expect(releases["R_1"]?.count == 1)
        #expect(releases["R_1"]?.first?.tagName == "v1.226.0")
        #expect(releases["R_1"]?.first?.tagCommitOid == "5e0c08f")
    }

    /// A draft release is not published, so nothing is running it and claiming a
    /// change shipped in it would be false.
    @Test("draft releases are dropped")
    func dropsDraftReleases() async throws {
        let body = Data("""
        {"data":{"nodes":[
          {"id":"R_1","releases":{"nodes":[
            {"tagName":"v2.0.0-draft","url":"https://github.com/acme/widget-service/releases/tag/v2",
             "createdAt":"2026-08-14T09:00:00Z","isDraft":true,"tagCommit":{"oid":"aaa"}},
            {"tagName":"v1.226.0","url":"https://github.com/acme/widget-service/releases/tag/v1.226.0",
             "createdAt":"2026-08-14T07:22:45Z","isDraft":false,"tagCommit":{"oid":"bbb"}}
          ]}}
        ]}}
        """.utf8)
        let ctx = makeClient([.response(status: 200, body: body)])

        let releases = try await ctx.client.fetchReleases(repoIDs: ["R_1"])
        #expect(releases["R_1"]?.map(\.tagName) == ["v1.226.0"])
    }

    /// A repository whose tag has no commit, or that GitHub could not resolve,
    /// must not take the other repositories' releases down with it.
    @Test("a null node is skipped rather than failing the whole lookup")
    func skipsNullNodes() async throws {
        let body = Data("""
        {"data":{"nodes":[null,
          {"id":"R_2","releases":{"nodes":[
            {"tagName":"v9.9.9","url":"https://github.com/acme/other/releases/tag/v9.9.9",
             "createdAt":"2026-08-14T07:22:45Z","isDraft":false,"tagCommit":{"oid":"ccc"}}
          ]}}
        ]}}
        """.utf8)
        let ctx = makeClient([.response(status: 200, body: body)])

        let releases = try await ctx.client.fetchReleases(repoIDs: ["R_1", "R_2"])
        #expect(releases["R_2"]?.count == 1)
        #expect(releases["R_1"] == nil)
    }

    // MARK: containment

    /// The mapping the whole version claim rests on: BEHIND and IDENTICAL mean
    /// the tag contains the commit, AHEAD means it does not.
    @Test("compare statuses map onto containment")
    func decodesContainment() async throws {
        let body = Data("""
        {"data":{
          "t0":{"ref":{"compare":{"status":"BEHIND"}}},
          "t1":{"ref":{"compare":{"status":"AHEAD"}}},
          "t2":{"ref":{"compare":{"status":"IDENTICAL"}}}
        }}
        """.utf8)
        let ctx = makeClient([.response(status: 200, body: body)])

        let answers = try await ctx.client.resolveContainment(
            [stubCandidate(pr: "PR_1", tag: "v1.0.0"),
             stubCandidate(pr: "PR_1", tag: "v0.9.0"),
             stubCandidate(pr: "PR_2", tag: "v2.0.0")]
        )

        #expect(answers[ContainmentKey(pullRequestID: "PR_1", tagName: "v1.0.0")] == true)
        #expect(answers[ContainmentKey(pullRequestID: "PR_1", tagName: "v0.9.0")] == false)
        #expect(answers[ContainmentKey(pullRequestID: "PR_2", tagName: "v2.0.0")] == true)
    }

    /// A tag GitHub cannot resolve answers nothing rather than answering "no" —
    /// the resolver treats an absent answer as unknown and keeps waiting, which
    /// is the difference between a slow answer and a wrong one.
    @Test("an unresolvable ref yields no answer rather than a false one")
    func unresolvableRefIsUnknown() async throws {
        let body = Data("""
        {"data":{"t0":{"ref":null}}}
        """.utf8)
        let ctx = makeClient([.response(status: 200, body: body)])

        let answers = try await ctx.client.resolveContainment(
            [stubCandidate(pr: "PR_1", tag: "v1.0.0")]
        )
        #expect(answers.isEmpty)
    }

    @Test("no candidates makes no request at all")
    func noCandidatesNoRequest() async throws {
        let ctx = makeClient([])
        let answers = try await ctx.client.resolveContainment([])
        #expect(answers.isEmpty)
        #expect(ctx.stub.requests.isEmpty)
    }

    // MARK: the retry applies to the new calls too

    @Test("a 401 on the releases lookup refreshes the token once and retries")
    func releasesRetryOn401() async throws {
        let body = Data("""
        {"data":{"nodes":[{"id":"R_1","releases":{"nodes":[]}}]}}
        """.utf8)
        let ctx = makeClient([
            .response(status: 401, body: Data("{}".utf8)),
            .response(status: 200, body: body),
        ])

        _ = try await ctx.client.fetchReleases(repoIDs: ["R_1"])
        #expect(ctx.stub.requests.count == 2)
        #expect(ctx.tokenReads.count == 2)
    }
}

private func stubCandidate(pr: String, tag: String) -> ContainmentCandidate {
    ContainmentCandidate(
        pullRequest: MergedPullRequest(
            id: pr,
            number: 1,
            title: "t",
            url: URL(string: "https://github.com/acme/widget-service/pull/1")!,
            repo: "acme/widget-service",
            repositoryID: "R_1",
            isPrivate: false,
            mergedAt: Date(timeIntervalSince1970: 1_000),
            mergeCommitOid: "abc",
            rollupState: .success,
            contexts: []
        ),
        release: Release(
            tagName: tag,
            url: URL(string: "https://github.com/acme/widget-service/releases/tag/\(tag)")!,
            tagCommitOid: "ddd",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
    )
}
