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
            files: files, isTruncated: false
        )
    }

    func setViewed(pullRequestID: String, path: String, viewed: Bool) async throws {
        throw PRMasterError.graphQL(["Viewed state isn't saved while the app shows debug data."])
    }
}
