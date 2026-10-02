import Foundation
import PRMasterCore

/// Serves one compare response to every review window, pinned to the live
/// row's own head so the window reads as current.
struct DiffFixtureClient: PullRequestDiffing {
    let path: String
    let liveRow: @MainActor @Sendable (String, Int) -> (id: String, head: String)?

    func loadDiff(repo: String, number: Int) async throws -> PullRequestDiff {
        let files = try DiffDecoder.compareFiles(try Data(contentsOf: URL(fileURLWithPath: path)))
        let row = await liveRow(repo, number)
        return PullRequestDiff(
            pullRequestID: row?.id ?? "fixture", baseOid: "fixture-base", headOid: row?.head ?? "fixture-head",
            files: files, isTruncated: false,
            descriptionHTML: try? String(contentsOfFile: descriptionPath, encoding: .utf8)
        )
    }

    /// `<fixture>.description.html` beside the compare fixture, when there is one.
    private var descriptionPath: String {
        URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("description.html").path
    }

    func setViewed(pullRequestID: String, path: String, viewed: Bool) async throws {
        throw PRMasterError.graphQL(["Viewed state isn't saved while the app shows debug data."])
    }
}

/// Scores by keyword, never over the network: for screenshots only.
struct FixtureScorer: BlockScoring {
    func score(path: String, blocks: [DiffBlock]) async throws -> BlockScores {
        try await Task.sleep(for: .milliseconds(150))
        return BlockScores(blocks: blocks.map { block in
            let lines = DiffBlocks.text(of: block).components(separatedBy: "\n").map(heat)
            return BlockScore(block: lines.max { $0.score < $1.score } ?? LineHeat(score: 1, confidence: 0.5), lines: lines)
        }, tooLarge: false)
    }

    private func heat(_ line: String) -> LineHeat {
        let lower = line.lowercased()
        if ["token", "auth", "password", "delete", "secret", "permission"].contains(where: lower.contains) {
            return LineHeat(score: 2.8, confidence: 0.8)
        }
        if ["if ", "guard ", "switch ", "throw ", ">", "<"].contains(where: lower.contains) { return LineHeat(score: 1.9, confidence: 0.6) }
        if ["import ", "case ", "let ", "var "].contains(where: lower.contains) { return LineHeat(score: 0.3, confidence: 0.8) }
        return LineHeat(score: 1.2, confidence: 0.3)
    }
}
