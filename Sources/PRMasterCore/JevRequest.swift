import Foundation

/// One System One request, the blocks it asks about by position in the file,
/// and which of their changed lines it asks about too.
struct JevBatch: Sendable, Equatable {
    let body: Data
    let blocks: [Int]
    /// Block position to the offsets, among its changed lines, that have their own question.
    let lines: [Int: [Int]]
    /// Block position to how many changed lines it has.
    let lineCounts: [Int: Int]
    let stateCharacters: Int
}

/// The wire format of OpenRouter's System One endpoint for Jev.
///
/// Blocks are named `b<position>` and their changed lines tagged `[l<offset>]`,
/// because Jev reads indexes and line numbers unreliably but follows a named key.
enum JevRequest {

    static let model = "typesafe/jev-1.13"
    static let maxLineCharacters = 500
    static let charactersPerToken = 3.0
    static let blockQuestionTokens = 160
    static let lineQuestionTokens = 110
    /// Jev's limit for the state plus its longest question is 32,000; its limit for a whole request about 65,000.
    static let maxStateTokens = 30_000
    static let maxRequestTokens = 60_000

    static let criteria = [
        "Glue: wiring, mapping between types, renames, imports, formatting, boilerplate",
        "Routine: plain logic whose effect is obvious from reading it",
        "Business logic: rules, calculations, conditions or state changes that decide what the product does",
        "Sensitive: authentication, permissions, money, deleting data, concurrency, migrations, secrets or input from outside",
    ]
    static let lineCriteria = [
        "Glue or boilerplate", "Routine logic", "Business logic", "Sensitive: security, secrets, data loss, concurrency",
    ]

    private struct Entry {
        let index: Int
        let text: String
        var lines: [Int]
        let lineCount: Int

        var stateTokens: Int { JevRequest.tokens(characters: text.count) }
        var questionTokens: Int { JevRequest.blockQuestionTokens + JevRequest.lineQuestionTokens * lines.count }
    }

    static func batches(path: String, blocks: [DiffBlock]) -> (batches: [JevBatch], tooLarge: [Int]) {
        var batches: [JevBatch] = []
        var tooLarge: [Int] = []
        var pending: [Entry] = []
        var stateTokens = 0, questionTokens = 0

        func flush() {
            guard !pending.isEmpty else { return }
            batches.append(batch(path: path, entries: pending))
            pending = []
            stateTokens = 0
            questionTokens = 0
        }

        for (index, block) in blocks.enumerated() {
            var entry = Entry(index: index, text: render(block), lines: askedLines(block), lineCount: block.changed.count)
            guard entry.stateTokens + blockQuestionTokens <= maxStateTokens else {
                tooLarge.append(index)
                continue
            }
            if entry.stateTokens + entry.questionTokens > maxRequestTokens { entry.lines = [] }
            let fitsState = stateTokens + entry.stateTokens + blockQuestionTokens <= maxStateTokens
            let fitsRequest = stateTokens + questionTokens + entry.stateTokens + entry.questionTokens <= maxRequestTokens
            if !(fitsState && fitsRequest) { flush() }
            pending.append(entry)
            stateTokens += entry.stateTokens
            questionTokens += entry.questionTokens
        }
        flush()
        return (batches, tooLarge)
    }

    static func estimatedStateTokens(_ batch: JevBatch) -> Int { tokens(characters: batch.stateCharacters) }

    static func estimatedTokens(_ batch: JevBatch) -> Int {
        estimatedStateTokens(batch) + blockQuestionTokens * batch.blocks.count
            + lineQuestionTokens * batch.lines.values.reduce(0) { $0 + $1.count }
    }

    /// By block position; a block with no answer at all is absent.
    static func scores(from data: Data, batch: JevBatch) throws -> [Int: BlockScore] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }
        var scores: [Int: BlockScore] = [:]
        for index in batch.blocks {
            let count = batch.lineCounts[index] ?? 0
            let lines = (0..<count).map { offset in response.answers[lineKey(index, offset)]?.heat }
            let block = response.answers[blockKey(index)]?.heat ?? lines.compactMap { $0 }.max { $0.score < $1.score }
            if let block { scores[index] = BlockScore(block: block, lines: lines) }
        }
        return scores
    }

    static func render(_ block: DiffBlock) -> String {
        var lines: [String] = []
        if !block.declaration.isEmpty { lines.append(String(("In " + block.declaration).prefix(maxLineCharacters))) }
        lines += block.before.map { String((" " + $0).prefix(maxLineCharacters)) }
        lines += block.changed.enumerated().map { "[l\($0.offset)] " + String($0.element.prefix(maxLineCharacters)) }
        lines += block.after.map { String((" " + $0).prefix(maxLineCharacters)) }
        return lines.joined(separator: "\n")
    }

    /// A line with no letter or digit, like a closing brace, says nothing on its own.
    private static func askedLines(_ block: DiffBlock) -> [Int] {
        block.changed.indices.filter { block.changed[$0].dropFirst().contains { $0.isLetter || $0.isNumber } }
    }

    private static func tokens(characters: Int) -> Int { Int((Double(characters) / charactersPerToken).rounded(.up)) }

    static let verification = Data("""
    {"model":"\(model)","provider":{"data_collection":"deny"},"state":"PRMaster connection check",\
    "questions":{"ok":{"type":"noul","instructions":"Is `state` a connection check?",\
    "criteria":{"true":"It is","false":"It is not"}}}}
    """.utf8)

    static func isVerificationAnswer(_ data: Data) -> Bool {
        struct Answers: Decodable { let answers: [String: Noul] }
        struct Noul: Decodable { let type: String; let noul: Double? }
        guard let answer = (try? JSONDecoder().decode(Answers.self, from: data))?.answers["ok"] else { return false }
        return answer.type == "noul" && answer.noul != nil
    }

    private static func blockKey(_ index: Int) -> String { "b\(index)" }
    private static func lineKey(_ index: Int, _ offset: Int) -> String { "b\(index)_l\(offset)" }

    private static func batch(path: String, entries: [Entry]) -> JevBatch {
        var questions: [String: Question] = [:]
        for entry in entries {
            let block = blockKey(entry.index)
            questions[block] = Question(
                instructions: "How closely must a human review the change in `blocks.\(block)`, all its lines together? "
                    + "Lines marked + were added and - removed. Judge what the code does, not what its comments claim.",
                criteria: criteria
            )
            for offset in entry.lines {
                questions[lineKey(entry.index, offset)] = Question(
                    instructions: "How closely must a human review the line tagged [l\(offset)] in `blocks.\(block)`, "
                        + "read with the rest of that block? Lines marked + were added and - removed. "
                        + "Judge what the code does, not what its comments claim.",
                    criteria: lineCriteria
                )
            }
        }
        let request = Body(
            model: model,
            state: State(path: path, blocks: Dictionary(uniqueKeysWithValues: entries.map { (blockKey($0.index), $0.text) })),
            questions: questions,
            provider: Provider()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return JevBatch(
            body: (try? encoder.encode(request)) ?? Data(),
            blocks: entries.map(\.index),
            lines: Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0.lines) }),
            lineCounts: Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0.lineCount) }),
            stateCharacters: entries.reduce(0) { $0 + $1.text.count }
        )
    }

    private struct Body: Encodable {
        let model: String
        let state: State
        let questions: [String: Question]
        let provider: Provider
    }

    private struct State: Encodable {
        let path: String
        let blocks: [String: String]
    }

    private struct Question: Encodable {
        let type = "score"
        let instructions: String
        let criteria: [String]
    }

    private struct Provider: Encodable {
        let data_collection = "deny"
    }

    private struct Response: Decodable {
        let answers: [String: Answer]
    }

    private struct Answer: Decodable {
        let score: Double?
        let confidence: Double?

        var heat: LineHeat? { score.map { LineHeat(score: $0, confidence: confidence) } }
    }
}
