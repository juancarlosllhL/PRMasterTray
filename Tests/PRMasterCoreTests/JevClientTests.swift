import Foundation
import Testing
@testable import PRMasterCore

/// Each error decides what the review window does next: stop for good, wait,
/// retry once, or give up on one file. Mapping a status wrongly either hammers
/// a dead key or abandons a file that one more try would have scored.
@Suite("Jev client")
struct JevClientTests {

    private func blocks(_ count: Int) throws -> [DiffBlock] {
        let patch = (0..<count).map { "@@ -\($0 * 10 + 1),1 +\($0 * 10 + 1),1 @@\n-old\($0) value\n+new\($0) value" }.joined(separator: "\n")
        return DiffBlocks.blocks(in: DiffFile(path: "a.swift", previousPath: nil, change: .modified, additions: 0,
                                              deletions: 0, content: .hunks(try PatchParser.hunks(patch))))
    }

    private func answers(_ scores: [Int: Double]) -> Data {
        let body = scores.map { "\"b\($0.key)\":{\"type\":\"score\",\"score\":\($0.value)}" }.joined(separator: ",")
        return Data("{\"id\":\"r\",\"model\":\"typesafe/jev-1.13\",\"answers\":{\(body)},\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}".utf8)
    }

    @Test("the request goes to OpenRouter's System One endpoint with the key as a bearer token")
    func requestShape() async throws {
        let stub = StubSession(outcomes: [.response(status: 200, body: answers([0: 1]))])
        _ = try await JevClient(token: "sk-or-test", session: stub.session).score(path: "a.swift", blocks: try blocks(1))

        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/systemone")
        #expect(request.headers["Authorization"] == "Bearer sk-or-test")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["User-Agent"] == "PRMaster")
        #expect(request.body?.isEmpty == false)
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self).contains("sk-or-test") == false)
    }

    @Test("answers come back as one score per block, and per line where the line was answered")
    func scores() async throws {
        let body = Data("""
        {"answers":{"b0":{"type":"score","score":0},"b1":{"type":"score","score":2.5,"confidence":0.8},
                    "b1_l1":{"type":"score","score":0.2,"confidence":0.9}}}
        """.utf8)
        let stub = StubSession(outcomes: [.response(status: 200, body: body)])
        let result = try await JevClient(token: "k", session: stub.session).score(path: "a.swift", blocks: try blocks(2))
        #expect(result.blocks.map { $0?.level } == [.glue, .sensitive])
        #expect(result.blocks[1]?.heat(ofLine: 0) == LineHeat(score: 2.5, confidence: 0.8))
        #expect(result.blocks[1]?.heat(ofLine: 1) == LineHeat(score: 0.2, confidence: 0.9))
        #expect(!result.tooLarge)
    }

    @Test("a file split over several requests merges every answer in block order")
    func merged() async throws {
        let fileBlocks = try blocks(300)
        let batches = JevRequest.batches(path: "a.swift", blocks: fileBlocks).batches
        #expect(batches.count > 1)
        let stub = StubSession(outcomes: batches.map { batch in
            .response(status: 200, body: answers(Dictionary(uniqueKeysWithValues: batch.blocks.map { ($0, $0 == 299 ? 3.0 : 0.0) })))
        })
        let result = try await JevClient(token: "k", session: stub.session).score(path: "a.swift", blocks: fileBlocks)
        #expect(stub.requests.count == batches.count)
        #expect(result.blocks.count == 300)
        #expect(result.blocks.last??.level == .sensitive)
        #expect(result.blocks.dropLast().allSatisfy { $0?.level == .glue })
    }

    @Test("a file with nothing to score makes no request")
    func nothingToScore() async throws {
        let stub = StubSession(outcomes: [])
        let result = try await JevClient(token: "k", session: stub.session).score(path: "a.swift", blocks: [])
        #expect(result == BlockScores(blocks: [], tooLarge: false))
        #expect(stub.requests.isEmpty)
    }

    @Test("statuses map to what the window does next", arguments: [
        (401, PRMasterError.heatmapUnauthorized),
        (403, .heatmapUnauthorized),
        (402, .heatmapNoCredits),
        (500, .heatmapUnavailable(status: 500)),
        (502, .heatmapUnavailable(status: 502)),
        (503, .heatmapUnavailable(status: 503)),
        (524, .heatmapUnavailable(status: 524)),
        (529, .heatmapUnavailable(status: 529)),
        (400, .heatmapRefused("HTTP 400")),
        (413, .heatmapRefused("HTTP 413")),
    ])
    func statuses(status: Int, expected: PRMasterError) async throws {
        let stub = StubSession(outcomes: [.response(status: status, body: Data("{}".utf8))])
        await #expect(throws: expected) {
            try await JevClient(token: "k", session: stub.session).score(path: "a.swift", blocks: try blocks(1))
        }
    }

    @Test("a rate limit says when to come back, from Retry-After")
    func rateLimited() async throws {
        let stub = StubSession(outcomes: [.response(status: 429, body: Data(), headers: ["Retry-After": "30"])])
        let before = Date()
        do {
            _ = try await JevClient(token: "k", session: stub.session).score(path: "a.swift", blocks: try blocks(1))
            Issue.record("expected a rate limit")
        } catch PRMasterError.rateLimited(let until) {
            #expect(until.timeIntervalSince(before) >= 29 && until.timeIntervalSince(before) <= 32)
        }
    }

    @Test("a rate limit without Retry-After waits a short fixed time")
    func rateLimitedWithoutHeader() async throws {
        let stub = StubSession(outcomes: [.response(status: 429, body: Data())])
        let before = Date()
        do {
            _ = try await JevClient(token: "k", session: stub.session).score(path: "a.swift", blocks: try blocks(1))
            Issue.record("expected a rate limit")
        } catch PRMasterError.rateLimited(let until) {
            #expect(until.timeIntervalSince(before) >= 9 && until.timeIntervalSince(before) <= 12)
        }
    }

    @Test("no network is worth another try, like a provider hiccup")
    func network() async throws {
        let stub = StubSession(outcomes: [.failure(URLError(.notConnectedToInternet))])
        await #expect(throws: PRMasterError.heatmapUnavailable(status: nil)) {
            try await JevClient(token: "k", session: stub.session).score(path: "a.swift", blocks: try blocks(1))
        }
    }

    @Test("an answer in the wrong shape is refused, since asking again gets the same answer")
    func unreadable() async throws {
        let stub = StubSession(outcomes: [.response(status: 200, body: Data("<html>".utf8))])
        await #expect(throws: PRMasterError.heatmapRefused("unreadable answer")) {
            try await JevClient(token: "k", session: stub.session).score(path: "a.swift", blocks: try blocks(1))
        }
    }

    @Test("checking a key asks one yes-or-no question, under the same retention terms")
    func verification() async throws {
        let ok = Data("{\"answers\":{\"ok\":{\"type\":\"noul\",\"noul\":0.9}}}".utf8)
        let stub = StubSession(outcomes: [.response(status: 200, body: ok), .response(status: 401, body: Data())])
        let client = JevClient(token: "k", session: stub.session)
        try await client.verify()
        let body = try #require(try JSONSerialization.jsonObject(with: stub.requests[0].body ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "typesafe/jev-1.13")
        #expect((body["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
        #expect(((body["questions"] as? [String: [String: Any]])?["ok"])?["type"] as? String == "noul")
        await #expect(throws: PRMasterError.heatmapUnauthorized) { try await client.verify() }
    }

    @Test("a proxy URL receives the request, under its own path")
    func customEndpoint() async throws {
        let stub = StubSession(outcomes: [.response(status: 200, body: answers([0: 1]))])
        let proxy = try OpenRouterEndpoint("https://llm-proxy.corp.example/openrouter/api/v1")
        _ = try await JevClient(token: "k", endpoint: proxy, session: stub.session).score(path: "a.swift", blocks: try blocks(1))
        #expect(stub.requests.first?.url?.absoluteString == "https://llm-proxy.corp.example/openrouter/api/v1/systemone")
    }

    @Test("a key check fails when something other than Jev answers 200, like a proxy's sign-in page")
    func verificationNeedsJev() async {
        let stub = StubSession(outcomes: [
            .response(status: 200, body: Data("<html>Sign in</html>".utf8)),
            .response(status: 200, body: Data("{\"answers\":{}}".utf8)),
        ])
        let client = JevClient(token: "k", session: stub.session)
        await #expect(throws: PRMasterError.heatmapRefused("not a Jev answer")) { try await client.verify() }
        await #expect(throws: PRMasterError.heatmapRefused("not a Jev answer")) { try await client.verify() }
    }

    @Test("the messages name OpenRouter, not GitHub")
    func messages() {
        for error in [PRMasterError.heatmapUnauthorized, .heatmapNoCredits, .heatmapUnavailable(status: 502),
                      .heatmapUnavailable(status: nil), .heatmapRefused("HTTP 413")] {
            let message = error.errorDescription ?? ""
            #expect(message.contains("OpenRouter"), "\(message)")
            #expect(!message.contains("GitHub"), "\(message)")
        }
    }
}
