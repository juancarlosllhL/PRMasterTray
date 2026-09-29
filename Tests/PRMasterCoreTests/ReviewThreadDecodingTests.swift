import Foundation
import Testing
@testable import PRMasterCore

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

@Suite("Review thread decoding")
struct ReviewThreadDecodingTests {

    /// PR_a holds a resolved Quill thread, an open Quill thread, an outdated
    /// open thread from a person, and an open thread from a deleted account.
    @Test("counts only unresolved threads, outdated ones included")
    func countsUnresolved() throws {
        let tallies = try PullRequestDecoder.decodeReviewThreads(try fixtureData("review-threads"))
        #expect(tallies["PR_a"]?.unresolved == 3)
    }

    /// A deleted account cannot be Quill, and its thread still blocks the merge.
    @Test("attributes Quill threads by login and nobody else's")
    func splitsByAuthor() throws {
        let tallies = try PullRequestDecoder.decodeReviewThreads(try fixtureData("review-threads"))
        #expect(tallies["PR_a"]?.unresolvedByQuill == 1)
        #expect(tallies["PR_a"]?.unresolvedByOthers == 2)
    }

    @Test("a PR GitHub could not resolve does not take the others down")
    func skipsNullNodes() throws {
        let tallies = try PullRequestDecoder.decodeReviewThreads(try fixtureData("review-threads"))
        #expect(tallies.count == 2)
        #expect(tallies["PR_b"] == ReviewThreadTally(unresolved: 0, unresolvedByQuill: 0))
    }

    @Test("an errors array throws rather than reading as no threads")
    func surfacesErrors() throws {
        #expect(throws: PRMasterError.self) {
            _ = try PullRequestDecoder.decodeReviewThreads(try fixtureData("graphql-errors"))
        }
    }

    @Test("the query asks for resolution state across the first hundred threads")
    func queryShape() {
        #expect(Queries.reviewThreads.contains("reviewThreads(first: 100)"))
        #expect(Queries.reviewThreads.contains("isResolved"))
        #expect(Queries.reviewThreads.contains("nodes(ids: $ids)"))
    }
}
