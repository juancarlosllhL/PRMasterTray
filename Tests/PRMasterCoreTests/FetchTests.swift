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
        #expect(prs.count == 4)
        #expect(prs.first?.repo == "acme/widget-service")
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
        #expect(prs.count == 4)
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
}
