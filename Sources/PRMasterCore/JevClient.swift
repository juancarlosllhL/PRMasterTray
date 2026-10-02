import Foundation

/// Scores blocks with Jev through OpenRouter.
public actor JevClient: BlockScoring {

    static let fallbackWait: TimeInterval = 10

    private let token: String
    private let endpoint: OpenRouterEndpoint
    private let session: URLSession

    public init(token: String, endpoint: OpenRouterEndpoint = .default, session: URLSession = .shared) {
        self.token = token
        self.endpoint = endpoint
        self.session = session
    }

    public init(key: OpenRouterKey, endpoint: OpenRouterEndpoint) {
        self.init(token: key.value, endpoint: endpoint)
    }

    public func score(path: String, blocks: [DiffBlock]) async throws -> BlockScores {
        let (batches, tooLarge) = JevRequest.batches(path: path, blocks: blocks)
        var scores = [BlockScore?](repeating: nil, count: blocks.count)
        for batch in batches {
            let data = try await send(batch.body)
            let answers: [Int: BlockScore]
            do {
                answers = try JevRequest.scores(from: data, batch: batch)
            } catch {
                throw PRMasterError.heatmapRefused("unreadable answer")
            }
            for (index, score) in answers { scores[index] = score }
        }
        return BlockScores(blocks: scores, tooLarge: !tooLarge.isEmpty)
    }

    /// One tiny question: proves the key, the credits and access to the model at once.
    /// A 200 alone proves nothing behind a proxy, whose sign-in page answers 200 too.
    func verify() async throws {
        let data = try await send(JevRequest.verification)
        guard JevRequest.isVerificationAnswer(data) else { throw PRMasterError.heatmapRefused("not a Jev answer") }
    }

    private func send(_ body: Data) async throws -> Data {
        var request = URLRequest(url: endpoint.systemOne)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PRMaster", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is URLError {
            throw PRMasterError.heatmapUnavailable(status: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw PRMasterError.heatmapUnavailable(status: nil) }

        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw PRMasterError.heatmapUnauthorized
        case 402:
            throw PRMasterError.heatmapNoCredits
        case 429:
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? Self.fallbackWait
            throw PRMasterError.rateLimited(until: Date().addingTimeInterval(wait))
        case 500...599:
            throw PRMasterError.heatmapUnavailable(status: http.statusCode)
        default:
            throw PRMasterError.heatmapRefused("HTTP \(http.statusCode)")
        }
    }
}
