import Foundation
import Testing
@testable import PRMasterCore

private func makeClient(_ outcomes: [StubOutcome]) -> (GitHubClient, StubSession) {
    let stub = StubSession(outcomes: outcomes)
    let provider = TokenProvider(
        paths: ["/fake/gh"],
        fileExists: { _ in true },
        run: { _ in TokenProvider.RunResult(stdout: "gho_faketokenvalue", exitCode: 0) }
    )
    return (GitHubClient(tokenProvider: provider, session: stub.session), stub)
}

private func json(_ string: String) -> StubOutcome {
    .response(status: 200, body: Data(string.utf8))
}

private func fixture(_ name: String) throws -> StubOutcome {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return .response(status: 200, body: try Data(contentsOf: url))
}

private let widgets = AppLocation(
    deploymentsRepo: "acme/widget-deployments",
    appPath: "widget-service"
)

/// The tree listing the cache tests reuse: two region-qualified files plus a
/// chart that is not a promotion, in a folder Kargo promotes into.
private let treeBody = """
{"data":{"t0":{"object":{"entries":[
  {"name":"Chart.yaml","object":{"oid":"chart"}},
  {"name":"kargo","object":{"oid":"kargo"}},
  {"name":"values.stg.euw1.yaml","object":{"oid":"oid-stg"}},
  {"name":"values.prd.euw1.yaml","object":{"oid":"oid-prd"}}
]}}}}
"""

private let blobBody = """
{"data":{
  "b0":{"object":{"text":"stableVersion: 3.32.0\\n"}},
  "b1":{"object":{"text":"stableVersion: 3.31.1\\n"}}
}}
"""

@Suite("Promotion client")
struct PromotionClientTests {

    // MARK: reading promotions

    @Test("the tree listing is followed by a blob read for unparsed content")
    func treeThenBlobs() async throws {
        let (client, stub) = makeClient([json(treeBody), json(blobBody)])

        let promotions = try await client.promotions(for: [widgets])

        #expect(stub.requests.count == 2)
        let versions = try #require(promotions[widgets])
        #expect(Set(versions.map(\.version)) == ["3.32.0", "3.31.1"])
        #expect(versions.contains { $0.file.environment == .staging && $0.version == "3.32.0" })
        #expect(versions.contains { $0.file.environment == .production && $0.version == "3.31.1" })
    }

    /// The whole point of carrying oids on the listing. These files change a few
    /// times a day; re-reading four of them every minute would be most of this
    /// feature's cost for none of its value.
    @Test("a second poll over unchanged content reads no blobs at all")
    func unchangedContentSkipsBlobs() async throws {
        let (client, stub) = makeClient([json(treeBody), json(blobBody), json(treeBody)])

        _ = try await client.promotions(for: [widgets])
        let second = try await client.promotions(for: [widgets])

        // Three in total: two for the first poll, and only the listing for the second.
        #expect(stub.requests.count == 3)
        #expect(Set(try #require(second[widgets]).map(\.version)) == ["3.32.0", "3.31.1"])
    }

    /// Only the file whose content moved is re-read.
    @Test("a changed oid is re-read while the unchanged one is not")
    func onlyChangedContentIsReRead() async throws {
        let movedTree = treeBody.replacingOccurrences(of: "oid-stg", with: "oid-stg-2")
        let movedBlob = """
        {"data":{"b0":{"object":{"text":"stableVersion: 3.33.0\\n"}}}}
        """
        let (client, stub) = makeClient([
            json(treeBody), json(blobBody), json(movedTree), json(movedBlob),
        ])

        _ = try await client.promotions(for: [widgets])
        let second = try await client.promotions(for: [widgets])

        #expect(stub.requests.count == 4)
        #expect(Set(try #require(second[widgets]).map(\.version)) == ["3.33.0", "3.31.1"])
    }

    /// The decommissioned folder that made this necessary. It still declares the
    /// image and still names a `stableVersion`, frozen at whatever was promoted
    /// the day it was switched off — a version no release can be found for, which
    /// silences the whole environment including the live app beside it.
    @Test("a folder with no kargo subscription is not read at all")
    func withoutKargoNothingIsRead() async throws {
        let abandoned = """
        {"data":{"t0":{"object":{"entries":[
          {"name":"Chart.yaml","object":{"oid":"chart"}},
          {"name":"values.stg.euw1.yaml","object":{"oid":"oid-frozen"}}
        ]}}}}
        """
        let (client, stub) = makeClient([json(abandoned)])

        #expect(try await client.promotions(for: [widgets]).isEmpty)
        #expect(stub.requests.count == 1)
    }

    /// A folder holding no region-qualified file has nothing to read, so the
    /// second request is skipped rather than sent empty.
    @Test("a folder with no promotion files issues no blob read")
    func noPromotionFilesNoBlobRead() async throws {
        let bare = """
        {"data":{"t0":{"object":{"entries":[
          {"name":"Chart.yaml","object":{"oid":"chart"}},
          {"name":"kargo","object":{"oid":"kargo"}}
        ]}}}}
        """
        let (client, stub) = makeClient([json(bare)])

        let promotions = try await client.promotions(for: [widgets])

        #expect(stub.requests.count == 1)
        #expect(promotions.isEmpty)
    }

    @Test("no locations issues no request at all")
    func noLocationsNoRequest() async throws {
        let (client, stub) = makeClient([])
        #expect(try await client.promotions(for: []).isEmpty)
        #expect(stub.requests.isEmpty)
    }

    /// A values file that names no version leaves that oid parsed but versionless,
    /// so it is not re-read on the next poll either.
    @Test("a file naming no version is not re-read on the next poll")
    func versionlessFileIsNotReRead() async throws {
        let onlyStg = """
        {"data":{"t0":{"object":{"entries":[
          {"name":"kargo","object":{"oid":"kargo"}},
          {"name":"values.stg.euw1.yaml","object":{"oid":"oid-stg"}}
        ]}}}}
        """
        let noVersion = """
        {"data":{"b0":{"object":{"text":"host: eu.example.com\\n"}}}}
        """
        let (client, stub) = makeClient([json(onlyStg), json(noVersion), json(onlyStg)])

        _ = try await client.promotions(for: [widgets])
        let second = try await client.promotions(for: [widgets])

        #expect(stub.requests.count == 3)
        #expect(second.isEmpty)
    }

    // MARK: discovery

    @Test("a repository with no CircleCI config discovers nothing rather than failing")
    func noConfigDiscoversNothing() async throws {
        let (client, stub) = makeClient([json(#"{"data":{"repository":{"object":null}}}"#)])

        #expect(try await client.discover(repo: "acme/widget-service").isEmpty)
        // The search is never reached, so no rate-limited call is spent.
        #expect(stub.requests.count == 1)
    }

    @Test("a config naming no image searches for nothing")
    func noImageNoSearch() async throws {
        let (client, stub) = makeClient([
            json(#"{"data":{"repository":{"object":{"text":"version: 2.1\n"}}}}"#)
        ])

        #expect(try await client.discover(repo: "acme/widget-service").isEmpty)
        #expect(stub.requests.count == 1)
    }

    @Test("the image name from the config drives a code search that yields locations")
    func discoversLocations() async throws {
        let config = #"{"data":{"repository":{"object":{"text":"    repository: acme-widget\n"}}}}"#
        let hits = """
        {"total_count":2,"items":[
          {"path":"widget-service/values.yaml","repository":{"full_name":"acme/widget-deployments"}},
          {"path":".stages/stg-euw1-core/widget-service/values.yaml","repository":{"full_name":"acme/widget-deployments"}}
        ]}
        """
        let declaring = #"{"data":{"repository":{"object":{"text":"appName: acme-widget\n"}}}}"#
        // Only the real hit is read: the rendered copy is dropped before costing
        // a request.
        let (client, stub) = makeClient([json(config), json(hits), json(declaring)])

        let locations = try await client.discover(repo: "acme/widget-service")

        #expect(locations == [widgets])
        #expect(stub.requests.count == 3)
        let search = try #require(stub.requests[1].url?.absoluteString)
        #expect(search.contains("search/code"))
        // Scoped to the service repository's own organisation.
        #expect(search.contains("acme"))
    }

    /// Code search matches substrings, so a file whose only occurrence of the
    /// image is inside an unrelated secret name comes back as a hit. Accepting
    /// it would put one service's versions on another service's rows.
    @Test("a hit that only mentions the image in passing is rejected")
    func mentionOnlyHitIsRejected() async throws {
        let config = #"{"data":{"repository":{"object":{"text":"    repository: acme-widget\n"}}}}"#
        let hits = """
        {"total_count":2,"items":[
          {"path":"widget-service/values.yaml","repository":{"full_name":"acme/widget-deployments"}},
          {"path":"gadget-service/values.yaml","repository":{"full_name":"acme/widget-deployments"}}
        ]}
        """
        let declaring = #"{"data":{"repository":{"object":{"text":"appName: acme-widget\n"}}}}"#
        let mentioning = #"""
        {"data":{"repository":{"object":{"text":"appName: acme-gadget\nsecretName: ch-acme-widget-credentials\n"}}}}
        """#
        let (client, stub) = makeClient([json(config), json(hits), json(declaring), json(mentioning)])

        #expect(try await client.discover(repo: "acme/widget-service") == [widgets])
        #expect(stub.requests.count == 4)
    }

    @Test("a hit whose file cannot be read is dropped rather than trusted")
    func unreadableHitIsDropped() async throws {
        let config = #"{"data":{"repository":{"object":{"text":"    repository: acme-widget\n"}}}}"#
        let hits = """
        {"total_count":1,"items":[
          {"path":"widget-service/values.yaml","repository":{"full_name":"acme/widget-deployments"}}
        ]}
        """
        let (client, stub) = makeClient([
            json(config), json(hits), json(#"{"data":{"repository":{"object":null}}}"#),
        ])

        #expect(try await client.discover(repo: "acme/widget-service").isEmpty)
        #expect(stub.requests.count == 3)
    }

    @Test("the search query is url encoded rather than pasted together")
    func searchIsEncoded() async throws {
        let config = #"{"data":{"repository":{"object":{"text":"    repository: acme-widget\n"}}}}"#
        let (client, stub) = makeClient([json(config), json(#"{"total_count":0,"items":[]}"#)])

        _ = try await client.discover(repo: "acme/widget-service")

        let url = try #require(stub.requests.last?.url)
        #expect(url.absoluteString.contains(" ") == false)

        let q = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value
        )
        #expect(q.contains("acme-widget"))
        #expect(q.contains("org:acme"))
        #expect(q.contains("filename:values.yaml"))
    }

    // MARK: failures

    @Test("a GraphQL errors array surfaces rather than reading as nothing promoted")
    func errorsSurface() async throws {
        let (client, _) = makeClient([try fixture("graphql-errors")])
        await #expect(throws: PRMasterError.self) {
            _ = try await client.promotions(for: [widgets])
        }
    }

    /// Code search is rate-limited far more tightly than the rest of the API and
    /// reports the secondary limit as a 403, which must not read as "no apps".
    @Test("a rate-limited search is reported, not swallowed as no locations")
    func rateLimitedSearchThrows() async throws {
        let config = #"{"data":{"repository":{"object":{"text":"    repository: acme-widget\n"}}}}"#
        let (client, _) = makeClient([
            json(config), .response(status: 403, body: Data(#"{"message":"rate limited"}"#.utf8)),
        ])

        await #expect(throws: PRMasterError.self) {
            _ = try await client.discover(repo: "acme/widget-service")
        }
    }
}
