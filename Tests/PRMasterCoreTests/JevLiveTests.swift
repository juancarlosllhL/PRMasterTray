import Foundation
import Testing
@testable import PRMasterCore

private let liveKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
private let liveEndpoint = (try? OpenRouterEndpoint(ProcessInfo.processInfo.environment["OPENROUTER_BASE_URL"] ?? "")) ?? .default

/// The only test that talks to the real model, so it runs only when a key is
/// set and never in CI. Set JEV_RECORD_PATH to keep the raw answer as a fixture.
@Suite("Jev live", .enabled(if: liveKey != nil))
struct JevLiveTests {

    private let patch = """
    @@ -1,3 +1,3 @@ func toDTO(_ order: Order) -> OrderDTO
     OrderDTO(
    -    id: order.id,
    +    id: order.identifier,
         total: order.total)
    @@ -20,3 +20,3 @@ func canRefund(_ user: User, _ order: Order) -> Bool
         guard user.isAuthenticated else { return false }
    -    return user.role == .admin
    +    return user.role == .admin || user.id == order.ownerID
     }
    """

    private var blocks: [DiffBlock] {
        let file = DiffFile(path: "Sources/Orders/Refunds.swift", previousPath: nil, change: .modified,
                            additions: 2, deletions: 2, content: .hunks(try! PatchParser.hunks(patch)))
        return DiffBlocks.blocks(in: file)
    }

    @Test("a field rename in a mapper scores below a change to who may refund")
    func mapperBelowPermission() async throws {
        let key = try OpenRouterKey(try #require(liveKey))
        let scores = try await JevClient(key: key, endpoint: liveEndpoint).score(path: "Sources/Orders/Refunds.swift", blocks: blocks)
        let mapper = try #require(scores.blocks[0])
        let permission = try #require(scores.blocks[1])
        #expect(mapper.block.score < permission.block.score, "mapper \(mapper.block), permission \(permission.block)")
    }

    @Test("the raw answer decodes with the documented shape")
    func recordsRawAnswer() async throws {
        let (batches, _) = JevRequest.batches(path: "Sources/Orders/Refunds.swift", blocks: blocks)
        let batch = try #require(batches.first)
        var request = URLRequest(url: liveEndpoint.systemOne)
        request.httpMethod = "POST"
        request.httpBody = batch.body
        request.setValue("Bearer \(try #require(liveKey))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let scores = try JevRequest.scores(from: data, batch: batch)
        #expect(scores.count == 2)
        #expect(scores.values.allSatisfy { score in score.lines.allSatisfy { $0 != nil } })
        if let path = ProcessInfo.processInfo.environment["JEV_RECORD_PATH"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
