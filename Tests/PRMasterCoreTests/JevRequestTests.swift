import Foundation
import Testing
@testable import PRMasterCore

/// The body is the whole contract with a paid, third-party model: what code
/// leaves the machine, under which retention terms, and how it is asked about.
@Suite("Jev request")
struct JevRequestTests {

    private func blocks(_ count: Int, linesEach: Int = 1, lineLength: Int = 10) -> [DiffBlock] {
        let line = String(repeating: "x", count: lineLength)
        let patch = (0..<count).map { index in
            "@@ -\(index * 1000 + 1),\(linesEach) +\(index * 1000 + 1),\(linesEach) @@\n"
                + Array(repeating: "-\(line)", count: linesEach).joined(separator: "\n") + "\n"
                + Array(repeating: "+\(line)", count: linesEach).joined(separator: "\n")
        }.joined(separator: "\n")
        return blocks(patch: patch)
    }

    private func blocks(patch: String) -> [DiffBlock] {
        let file = DiffFile(path: "Sources/Billing.swift", previousPath: nil, change: .modified,
                            additions: 0, deletions: 0, content: .hunks(try! PatchParser.hunks(patch)))
        return DiffBlocks.blocks(in: file)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func questions(_ batch: JevBatch) throws -> [String: [String: Any]] {
        try #require(try json(batch.body)["questions"] as? [String: [String: Any]])
    }

    private let charge = "@@ -1,3 +1,3 @@ func charge()\n let a = 1\n-let fee = 2\n+let fee = 3\n let c = 4"

    @Test("one request names the pinned model and forbids providers from keeping the code")
    func modelAndRetention() throws {
        let batch = try #require(JevRequest.batches(path: "Sources/Billing.swift", blocks: blocks(1)).batches.first)
        let body = try json(batch.body)
        #expect(body["model"] as? String == "typesafe/jev-1.13")
        #expect((body["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
    }

    @Test("the state carries the path and each block, with every changed line tagged")
    func state() throws {
        let batch = try #require(JevRequest.batches(path: "Sources/Billing.swift", blocks: blocks(patch: charge)).batches.first)
        let state = try #require(try json(batch.body)["state"] as? [String: Any])
        #expect(state["path"] as? String == "Sources/Billing.swift")
        let block = try #require((state["blocks"] as? [String: String])?["b0"])
        #expect(block == "In func charge()\n let a = 1\n[l0] -let fee = 2\n[l1] +let fee = 3\n let c = 4")
    }

    @Test("each block gets a question over the four levels, and each changed line its own")
    func blockAndLineQuestions() throws {
        let batch = try #require(JevRequest.batches(path: "p", blocks: blocks(patch: charge)).batches.first)
        let asked = try questions(batch)
        #expect(Set(asked.keys) == ["b0", "b0_l0", "b0_l1"])
        let block = try #require(asked["b0"])
        #expect(block["type"] as? String == "score")
        #expect((block["instructions"] as? String)?.contains("`blocks.b0`") == true)
        #expect((block["criteria"] as? [String])?.count == 4)
        let line = try #require(asked["b0_l1"])
        #expect(line["type"] as? String == "score")
        #expect((line["instructions"] as? String)?.contains("[l1]") == true)
        #expect((line["instructions"] as? String)?.contains("`blocks.b0`") == true)
        let criteria = try #require(line["criteria"] as? [String])
        #expect(criteria.count == 4)
        #expect(criteria.first?.hasPrefix("Glue") == true)
        #expect(criteria.last?.hasPrefix("Sensitive") == true)
    }

    @Test("a line with no letter or digit is not asked about: it takes its block's score")
    func trivialLinesSkipped() throws {
        let patch = "@@ -1,2 +1,5 @@\n keep\n-old()\n+if ready {\n+\n+}\n+    })"
        let batch = try #require(JevRequest.batches(path: "p", blocks: blocks(patch: patch)).batches.first)
        #expect(Set(try questions(batch).keys) == ["b0", "b0_l0", "b0_l1"])
    }

    @Test("many blocks are split across requests by token budget, each block asked about exactly once")
    func splitByBudget() throws {
        let result = JevRequest.batches(path: "p", blocks: blocks(400, linesEach: 1, lineLength: 40))
        #expect(result.batches.count > 1)
        #expect(result.batches.flatMap(\.blocks) == Array(0..<400))
        #expect(result.tooLarge.isEmpty)
        for batch in result.batches {
            #expect(JevRequest.estimatedTokens(batch) <= JevRequest.maxRequestTokens)
            #expect(JevRequest.estimatedStateTokens(batch) + JevRequest.blockQuestionTokens <= JevRequest.maxStateTokens)
        }
    }

    @Test("a block with too many lines for per-line questions is still scored as a block")
    func blockOnlyFallback() throws {
        let result = JevRequest.batches(path: "p", blocks: blocks(1, linesEach: 350, lineLength: 20))
        let batch = try #require(result.batches.first)
        #expect(result.tooLarge.isEmpty)
        #expect(Array(try questions(batch).keys) == ["b0"])
        #expect(JevRequest.estimatedTokens(batch) <= JevRequest.maxRequestTokens)
    }

    @Test("a block too big for any request is reported and never sent")
    func tooLarge() {
        let result = JevRequest.batches(path: "p", blocks: blocks(1, linesEach: 120, lineLength: 500))
        #expect(result.batches.isEmpty)
        #expect(result.tooLarge == [0])
    }

    @Test("a very long line is cut, so minified code cannot fill a request on its own")
    func longLines() throws {
        let batch = try #require(JevRequest.batches(path: "p", blocks: blocks(1, lineLength: 5000)).batches.first)
        let text = try #require(((try json(batch.body)["state"] as? [String: Any])?["blocks"] as? [String: String])?["b0"])
        for line in text.split(separator: "\n") {
            #expect(line.count <= JevRequest.maxLineCharacters + 6)
        }
    }

    /// Measured on jev-1.13 through OpenRouter on 2026-09-30: tagged text costs about 3.3 characters
    /// a token, a block question about 150 tokens and a line question about 100.
    @Test("the budget sits inside Jev's limits at the measured costs")
    func budgetMatchesMeasurements() {
        #expect(JevRequest.charactersPerToken <= 3.3)
        #expect(JevRequest.blockQuestionTokens >= 150)
        #expect(JevRequest.lineQuestionTokens >= 100)
        #expect(JevRequest.maxStateTokens < 32_000)
        #expect(JevRequest.maxRequestTokens < 64_000)
    }

    @Test("answers map back to their block and line; a line without an answer takes the block's")
    func decoding() throws {
        let patch = "@@ -1,2 +1,1 @@\n-a = 1\n-b = 2\n+c = 3"
        let batch = try #require(JevRequest.batches(path: "p", blocks: blocks(patch: patch)).batches.first)
        let response = Data("""
        {"id":"x","model":"typesafe/jev-1.13","provider":"TypeSafe",
         "answers":{"b0":{"type":"score","score":1.2,"confidence":0.6},
                    "b0_l0":{"type":"score","score":2.6,"confidence":0.8},
                    "b0_l2":{"type":"score","score":0.1,"confidence":0.2}},
         "usage":{"input_tokens":120,"output_tokens":3,"cost":0.00001}}
        """.utf8)
        let scores = try JevRequest.scores(from: response, batch: batch)
        let score = try #require(scores[0])
        #expect(score.block == LineHeat(score: 1.2, confidence: 0.6))
        #expect(score.heat(ofLine: 0) == LineHeat(score: 2.6, confidence: 0.8))
        #expect(score.heat(ofLine: 1) == score.block)
        #expect(score.heat(ofLine: 2).isUncertain)
    }

    @Test("without a block answer the block takes its hottest line; with no answer at all it stays unscored")
    func missingBlockAnswer() throws {
        let patch = "@@ -1,1 +1,1 @@\n-a = 1\n+a = 2\n@@ -10,1 +10,1 @@\n-b = 1\n+b = 2"
        let batch = try #require(JevRequest.batches(path: "p", blocks: blocks(patch: patch)).batches.first)
        let response = Data("""
        {"answers":{"b0_l0":{"type":"score","score":0.4},"b0_l1":{"type":"score","score":2.2,"confidence":0.7}}}
        """.utf8)
        let scores = try JevRequest.scores(from: response, batch: batch)
        #expect(scores[0]?.block == LineHeat(score: 2.2, confidence: 0.7))
        #expect(scores[1] == nil)
    }

    @Test("a real answer, recorded through OpenRouter, decodes into every block and line it was asked about")
    func recordedAnswer() throws {
        let patch = """
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
        let batch = try #require(JevRequest.batches(path: "Sources/Orders/Refunds.swift", blocks: blocks(patch: patch)).batches.first)
        let url = try #require(Bundle.module.url(forResource: "jev-response", withExtension: "json", subdirectory: "Fixtures"))
        let scores = try JevRequest.scores(from: Data(contentsOf: url), batch: batch)
        let mapper = try #require(scores[0]), refund = try #require(scores[1])
        #expect(mapper.lines.allSatisfy { $0 != nil } && refund.lines.allSatisfy { $0 != nil })
        #expect(mapper.block.confidence != nil)
        #expect(mapper.level < refund.level)
        #expect(refund.level == .sensitive)
    }

    @Test("a body that is not the documented shape is a decoding failure, not silence")
    func badResponse() throws {
        let batch = try #require(JevRequest.batches(path: "p", blocks: blocks(1)).batches.first)
        #expect(throws: PRMasterError.self) {
            try JevRequest.scores(from: Data("{\"error\":1}".utf8), batch: batch)
        }
    }
}
