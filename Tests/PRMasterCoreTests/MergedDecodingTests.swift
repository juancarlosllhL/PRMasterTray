import Foundation
import Testing
@testable import PRMasterCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture \(name).json"
    )
    return try Data(contentsOf: url)
}

@Suite("Merged pull request decoding")
struct MergedDecodingTests {

    @Test("decodes the merged half of a dual-aliased search")
    func decodesMergedHalf() throws {
        let merged = try PullRequestDecoder.decodeMergedSearch(try fixture("merged-search"))
        #expect(merged.count == 4)
    }

    @Test("flattens the nested shape onto the domain model")
    func flattensNesting() throws {
        let pr = try #require(
            try PullRequestDecoder.decodeMergedSearch(try fixture("merged-search")).first
        )
        #expect(pr.id == "PR_kwDOAAAAAA80mQrs")
        #expect(pr.number == 1204)
        #expect(pr.repo == "acme/widget-service")
        // The node ID is what feeds nodes(ids:) for the releases lookup, so it
        // has to survive the round trip untouched.
        #expect(pr.repositoryID == "R_kgDOAAAAAQ")
        #expect(pr.isPrivate == false)
        #expect(pr.mergeCommitOid == "9f4c1ab7e0d25c3184bb6f70a1e5d8c92374ef60")
        // 2026-08-14T07:22:45Z
        #expect(pr.mergedAt == Date(timeIntervalSince1970: 1786692165))
        #expect(pr.organization == "acme")
    }

    // MARK: normalising two wire shapes into one

    /// `CheckRun` and `StatusContext` are different types on the wire with
    /// different state fields. Everything downstream reads one shape, so the
    /// collapse has to happen here or every consumer pays for it.
    @Test("a running CheckRun and a pending StatusContext both read as pending")
    func normalisesPendingAcrossBothShapes() throws {
        let pr = try #require(
            try PullRequestDecoder.decodeMergedSearch(try fixture("merged-search")).first
        )

        let cd = try #require(pr.contexts.first { $0.name == "CD" })
        #expect(cd.state == .pending)
        #expect(cd.isWorkflow)
        #expect(cd.url?.host == "app.circleci.com")

        let push = try #require(
            pr.contexts.first { $0.name == "ci/circleci: build-and-push-image" }
        )
        #expect(push.state == .pending)
        // A StatusContext addresses one job, not the workflow that contains it.
        #expect(push.isWorkflow == false)
    }

    @Test("a completed CheckRun reads as its conclusion, not its status")
    func completedCheckRunUsesConclusion() throws {
        let pr = try #require(
            try PullRequestDecoder.decodeMergedSearch(try fixture("merged-search")).first
        )
        let onMaster = try #require(pr.contexts.first { $0.name == "on_master" })
        #expect(onMaster.state == .success)
    }

    /// The same tolerance rule the open-PR enums follow: GitHub adds values, and
    /// one unfamiliar string must not blank the list. `pending` is the safe
    /// reading — `success` would claim a change shipped on no evidence.
    @Test("an unknown conclusion degrades to pending rather than throwing")
    func unknownConclusionDegrades() throws {
        let merged = try PullRequestDecoder.decodeMergedSearch(try fixture("merged-search"))
        let pr = try #require(merged.first { $0.number == 902 })
        let cd = try #require(pr.contexts.first { $0.name == "CD" })
        #expect(cd.state == .pending)
    }

    @Test("a context without a URL decodes with a nil URL")
    func missingURLDecodes() throws {
        let merged = try PullRequestDecoder.decodeMergedSearch(try fixture("merged-search"))
        let pr = try #require(merged.first { $0.number == 902 })
        let release = try #require(pr.contexts.first { $0.name == "ci/circleci: release" })
        #expect(release.url == nil)
    }

    /// The rollup's own state is kept as well as the individual contexts.
    /// It is GitHub's summary over *every* check, including any context type
    /// this app does not recognise and therefore drops, which makes it the
    /// authority on whether everything passed. The contexts exist to name the
    /// failure and to link to it, not to be counted.
    @Test("keeps the rollup state alongside the contexts")
    func keepsRollupState() throws {
        let merged = try PullRequestDecoder.decodeMergedSearch(try fixture("merged-search"))

        let building = try #require(merged.first { $0.number == 1204 })
        #expect(building.rollupState == .pending)

        // No CI at all is not the same as no result yet.
        let noCI = try #require(merged.first { $0.number == 77 })
        #expect(noCI.rollupState == nil)
    }

    // MARK: the two absences that are not failures

    /// GitHub takes seconds to materialise the merge commit. A pull request
    /// merged moments ago is not a decoding failure, and must not throw away the
    /// other three rows with it.
    @Test("a null mergeCommit decodes with a nil oid rather than throwing")
    func nullMergeCommitDecodes() throws {
        let merged = try PullRequestDecoder.decodeMergedSearch(try fixture("merged-search"))
        let pr = try #require(merged.first { $0.number == 318 })
        #expect(pr.mergeCommitOid == nil)
        #expect(pr.contexts.isEmpty)
    }

    /// Distinct from "checks running": a repository with no CI at all reports a
    /// null rollup, and has an oid regardless.
    @Test("a null rollup decodes as no contexts, with the oid intact")
    func nullRollupDecodes() throws {
        let merged = try PullRequestDecoder.decodeMergedSearch(try fixture("merged-search"))
        let pr = try #require(merged.first { $0.number == 77 })
        #expect(pr.mergeCommitOid == "3b8e07d5c94a26f1e83b0d4759ac6182f0e7b3d4")
        #expect(pr.contexts.isEmpty)
    }

    // MARK: envelope

    @Test("a GraphQL errors array throws rather than reporting nothing merged")
    func errorsThrow() throws {
        #expect(throws: PRMasterError.self) {
            try PullRequestDecoder.decodeMergedSearch(try fixture("graphql-errors"))
        }
    }
}
