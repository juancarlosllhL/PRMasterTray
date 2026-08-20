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

private let widgets = AppLocation(
    deploymentsRepo: "acme/widget-deployments",
    appPath: "widget-service"
)
private let gadgets = AppLocation(
    deploymentsRepo: "acme/gadget-deployments",
    appPath: "gadget-service"
)

private func tagRequest(_ version: String) -> ReleaseTagRequest {
    ReleaseTagRequest(repo: "acme/widget-service", repositoryID: "R_1", version: version)
}

private func tagBody(prefixed: String, bare: String) -> Data {
    Data(#"{"data":{"r0":{"prefixed":\#(prefixed),"bare":\#(bare)}}}"#.utf8)
}

/// Splits a built document into the variable names it declares, the same way
/// `QueriesTests` does.
private func declaredVariables(in query: String) -> Set<String> {
    Set(
        query
            .split(whereSeparator: { " (,:)\n".contains($0) })
            .filter { $0.hasPrefix("$") }
            .map { String($0.dropFirst()) }
    )
}

@Suite("Promotion queries")
struct PromotionQueryTests {

    // MARK: the tree listing

    @Test("each app folder gets its own alias")
    func treeAliases() throws {
        let built = try #require(Queries.promotionTrees(for: [widgets, gadgets]))
        #expect(built.query.contains("t0: repository("))
        #expect(built.query.contains("t1: repository("))
    }

    /// The second query in this app assembled from data GitHub sent us. Repo
    /// names and app paths are remote strings; if one reached the document text,
    /// escaping would become this app's problem — and it should not be.
    @Test("no remote value appears anywhere in the tree document")
    func noRemoteValueInTreeDocument() throws {
        let built = try #require(Queries.promotionTrees(for: [widgets]))
        #expect(built.query.contains("acme") == false)
        #expect(built.query.contains("widget-deployments") == false)
        #expect(built.query.contains("widget-service") == false)
    }

    @Test("every declared tree variable has a value bound to it")
    func treeVariablesAllBound() throws {
        let built = try #require(Queries.promotionTrees(for: [widgets, gadgets]))
        let declared = declaredVariables(in: built.query)
        #expect(declared.isEmpty == false)
        #expect(declared == Set(built.variables.keys))
    }

    @Test("the owner and name of a deployments repository are split apart")
    func splitsOwnerAndName() throws {
        let built = try #require(Queries.promotionTrees(for: [widgets]))
        #expect(built.variables["owner0"] == "acme")
        #expect(built.variables["name0"] == "widget-deployments")
    }

    /// `HEAD` rather than a branch name: nothing guarantees every deployments
    /// repository calls its default branch `main`, and a wrong branch would read
    /// as an app that has never been promoted to.
    @Test("the tree is addressed at HEAD, and the path rides as a variable")
    func treeExpressionIsAVariable() throws {
        let built = try #require(Queries.promotionTrees(for: [widgets]))
        #expect(built.variables["tree0"] == "HEAD:widget-service")
        #expect(built.query.contains("HEAD:") == false)
    }

    @Test("no locations yields no tree query")
    func noLocationsNoTreeQuery() {
        #expect(Queries.promotionTrees(for: []) == nil)
    }

    // MARK: the blob reads

    @Test("each blob gets its own alias and its expression rides as a variable")
    func blobAliasesAndExpressions() throws {
        let built = try #require(Queries.promotionBlobs(for: [
            BlobRequest(location: widgets, file: "values.stg.euw1.yaml", oid: "b1"),
            BlobRequest(location: widgets, file: "values.prd.euw1.yaml", oid: "b2"),
        ]))

        #expect(built.query.contains("b0: repository("))
        #expect(built.query.contains("b1: repository("))
        #expect(built.variables["blob0"] == "HEAD:widget-service/values.stg.euw1.yaml")
        #expect(built.variables["blob1"] == "HEAD:widget-service/values.prd.euw1.yaml")
    }

    @Test("no remote value appears anywhere in the blob document")
    func noRemoteValueInBlobDocument() throws {
        let built = try #require(Queries.promotionBlobs(for: [
            BlobRequest(location: widgets, file: "values.stg.euw1.yaml", oid: "b1"),
        ]))
        #expect(built.query.contains("acme") == false)
        #expect(built.query.contains("widget-service") == false)
        #expect(built.query.contains("values.stg.euw1.yaml") == false)
    }

    @Test("every declared blob variable has a value bound to it")
    func blobVariablesAllBound() throws {
        let built = try #require(Queries.promotionBlobs(for: [
            BlobRequest(location: widgets, file: "values.stg.euw1.yaml", oid: "b1"),
            BlobRequest(location: gadgets, file: "values.prd.use2.yaml", oid: "b2"),
        ]))
        let declared = declaredVariables(in: built.query)
        #expect(declared.isEmpty == false)
        #expect(declared == Set(built.variables.keys))
    }

    @Test("no requests yields no blob query")
    func noRequestsNoBlobQuery() {
        #expect(Queries.promotionBlobs(for: []) == nil)
    }

    // MARK: decoding

    @Test("tree entries decode with their names and oids")
    func decodesTreeEntries() throws {
        let trees = try PullRequestDecoder.decodePromotionTrees(
            try fixture("promotion-trees"), locations: [widgets, gadgets]
        )

        let entries = try #require(trees[widgets])
        #expect(entries.contains { $0.name == "values.stg.euw1.yaml" })
        let stg = try #require(entries.first { $0.name == "values.stg.euw1.yaml" })
        #expect(stg.oid == "3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b42")
    }

    /// A folder GitHub could not resolve is left out rather than recorded as
    /// empty: an app whose tree failed to load has not been proven to have no
    /// promotions.
    @Test("an app folder that does not resolve is omitted")
    func omitsUnresolvedFolder() throws {
        let trees = try PullRequestDecoder.decodePromotionTrees(
            try fixture("promotion-trees"), locations: [widgets, gadgets]
        )
        #expect(trees[gadgets] == nil)
    }

    @Test("blob text decodes keyed by the oid that was asked for")
    func decodesBlobs() throws {
        let requests = [
            BlobRequest(location: widgets, file: "values.stg.euw1.yaml", oid: "oid-stg"),
            BlobRequest(location: widgets, file: "values.prd.euw1.yaml", oid: "oid-prd"),
            BlobRequest(location: widgets, file: "values.stg.use2.yaml", oid: "oid-gone"),
        ]
        let blobs = try PullRequestDecoder.decodePromotionBlobs(
            try fixture("promotion-blobs"), requests: requests
        )

        #expect(PromotionFile.stableVersion(in: try #require(blobs["oid-stg"])) == "3.32.0")
        #expect(PromotionFile.stableVersion(in: try #require(blobs["oid-prd"])) == "3.31.1")
        // A blob GitHub did not return is absent, not an empty string that would
        // parse as an app with no promoted version.
        #expect(blobs["oid-gone"] == nil)
    }

    // MARK: identifying a release by the version promoted into an environment

    @Test("each version gets its own alias, holding both spellings of the tag")
    func releaseTagAliases() throws {
        let built = try #require(Queries.releasesByTag(for: [tagRequest("3.31.1"), tagRequest("3.40.0")]))
        #expect(built.query.contains("r0: repository("))
        #expect(built.query.contains("r1: repository("))
        #expect(built.query.contains("prefixed: release("))
        #expect(built.query.contains("bare: release("))
    }

    /// The version in a values file carries no prefix and the tag usually does.
    /// Asking both in one document costs one request, because GitHub answers a
    /// tag that does not exist with null rather than with an error.
    @Test("both spellings of the tag ride as variables")
    func bothSpellingsAreBound() throws {
        let built = try #require(Queries.releasesByTag(for: [tagRequest("3.31.1")]))
        #expect(built.variables["prefixed0"] == "v3.31.1")
        #expect(built.variables["bare0"] == "3.31.1")
        #expect(built.variables["owner0"] == "acme")
        #expect(built.variables["name0"] == "widget-service")
    }

    @Test("no remote value appears anywhere in the release document")
    func noRemoteValueInReleaseDocument() throws {
        let built = try #require(Queries.releasesByTag(for: [tagRequest("3.31.1")]))
        #expect(built.query.contains("acme") == false)
        #expect(built.query.contains("widget-service") == false)
        #expect(built.query.contains("3.31.1") == false)
    }

    @Test("every declared release variable has a value bound to it")
    func releaseVariablesAllBound() throws {
        let built = try #require(Queries.releasesByTag(for: [tagRequest("3.31.1"), tagRequest("3.40.0")]))
        let declared = declaredVariables(in: built.query)
        #expect(declared.isEmpty == false)
        #expect(declared == Set(built.variables.keys))
    }

    @Test("no requests yields no release query")
    func noRequestsNoReleaseQuery() {
        #expect(Queries.releasesByTag(for: []) == nil)
    }

    @Test("the prefixed spelling wins when both answer")
    func prefixedWins() throws {
        let body = tagBody(
            prefixed: #"{"tagName":"v3.31.1","url":"https://e.com/v","createdAt":"2026-08-13T12:42:51Z","isDraft":false,"tagCommit":{"oid":"aaa"}}"#,
            bare: #"{"tagName":"3.31.1","url":"https://e.com/b","createdAt":"2026-08-13T12:42:51Z","isDraft":false,"tagCommit":{"oid":"bbb"}}"#
        )
        let releases = try PullRequestDecoder.decodeTagReleases(body, requests: [tagRequest("3.31.1")])
        #expect(releases["R_1"]?.map(\.tagName) == ["v3.31.1"])
    }

    @Test("the bare spelling is used when it is the only answer")
    func bareIsUsedAlone() throws {
        let body = tagBody(
            prefixed: "null",
            bare: #"{"tagName":"3.31.1","url":"https://e.com/b","createdAt":"2026-08-13T12:42:51Z","isDraft":false,"tagCommit":{"oid":"bbb"}}"#
        )
        let releases = try PullRequestDecoder.decodeTagReleases(body, requests: [tagRequest("3.31.1")])
        #expect(releases["R_1"]?.map(\.tagName) == ["3.31.1"])
    }

    /// A version nothing is tagged with stays absent rather than arriving as a
    /// release with no commit: unknown and wrong are different answers.
    @Test("a version neither spelling resolves is absent")
    func unresolvedVersionIsAbsent() throws {
        let releases = try PullRequestDecoder.decodeTagReleases(
            tagBody(prefixed: "null", bare: "null"), requests: [tagRequest("3.31.1")]
        )
        #expect(releases.isEmpty)
    }

    /// Nothing is running a release that was never published, so calling a
    /// change shipped in one would be false — the same rule the depth-based
    /// lookup follows.
    @Test("a draft is not the release an environment is on")
    func draftIsNotARelease() throws {
        let body = tagBody(
            prefixed: #"{"tagName":"v3.31.1","url":"https://e.com/v","createdAt":"2026-08-13T12:42:51Z","isDraft":true,"tagCommit":{"oid":"aaa"}}"#,
            bare: "null"
        )
        #expect(try PullRequestDecoder.decodeTagReleases(body, requests: [tagRequest("3.31.1")]).isEmpty)
    }

    @Test("a GraphQL errors array throws rather than reporting nothing promoted", arguments: [true, false])
    func errorsThrow(trees: Bool) throws {
        let data = try fixture("graphql-errors")
        #expect(throws: PRMasterError.self) {
            if trees {
                _ = try PullRequestDecoder.decodePromotionTrees(data, locations: [widgets])
            } else {
                _ = try PullRequestDecoder.decodePromotionBlobs(
                    data, requests: [BlobRequest(location: widgets, file: "values.yaml", oid: "x")]
                )
            }
        }
    }
}
