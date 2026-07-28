import Foundation
import Testing
@testable import PRMasterCore

private func makeClient(_ outcomes: [StubOutcome], assetName: String = "PRMaster.app.zip")
    -> (client: ReleaseClient, stub: StubSession) {
    let stub = StubSession(outcomes: outcomes)
    return (
        ReleaseClient(repo: "acme/PRMaster", assetName: assetName, session: stub.session),
        stub
    )
}

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

/// The release check is unauthenticated and runs on a timer, so every failure
/// mode has to resolve to something the popover can either show or ignore —
/// never to a crash and never to a silently wrong "you are up to date".
@Suite("Release client")
struct ReleaseClientTests {

    // MARK: request shape

    @Test("asks GitHub for the repo's latest release")
    func requestShape() async throws {
        let ctx = makeClient([.response(status: 200, body: try fixtureData("release-latest"))])
        _ = try await ctx.client.fetchLatestRelease()

        let request = try #require(ctx.stub.requests.first)
        #expect(
            request.url?.absoluteString
                == "https://api.github.com/repos/acme/PRMaster/releases/latest"
        )
        #expect(request.headers["Accept"] == "application/vnd.github+json")
    }

    /// The check must not carry the user's `gh` token. It reads a public repo,
    /// and sending a credential where none is needed only widens the blast
    /// radius of a mistake.
    @Test("sends no authorization header")
    func sendsNoCredential() async throws {
        let ctx = makeClient([.response(status: 200, body: try fixtureData("release-latest"))])
        _ = try await ctx.client.fetchLatestRelease()

        let request = try #require(ctx.stub.requests.first)
        #expect(request.headers["Authorization"] == nil)
    }

    // MARK: decoding

    @Test("maps the release and its named asset onto AppRelease")
    func decodesRelease() async throws {
        let ctx = makeClient([.response(status: 200, body: try fixtureData("release-latest"))])
        let release = try await ctx.client.fetchLatestRelease()

        #expect(release.tag == "v0.2.0")
        #expect(release.version == "0.2.0")
        #expect(
            release.assetURL.absoluteString
                == "https://github.com/juancarlosllhL/PRMaster/releases/download/v0.2.0/PRMaster.app.zip"
        )
        #expect(
            release.sha256
                == "sha256:d99c34544838251ca1dd2d7fc6770de4d6f412108349647c3fad5056149a3329"
        )
    }

    /// Assets uploaded before GitHub started publishing digests have no
    /// `digest` field. Decoding still has to succeed — it is the installer that
    /// refuses, so the popover can at least say a version exists.
    @Test("tolerates an asset with no digest")
    func missingDigestStillDecodes() async throws {
        let body = Data("""
        {"tag_name":"v0.3.0","assets":[
          {"name":"PRMaster.app.zip",
           "browser_download_url":"https://example.com/PRMaster.app.zip"}
        ]}
        """.utf8)
        let ctx = makeClient([.response(status: 200, body: body)])
        let release = try await ctx.client.fetchLatestRelease()

        #expect(release.version == "0.3.0")
        #expect(release.sha256 == nil)
    }

    /// Real releases carry source tarballs and any other file that was attached.
    /// Picking the first asset would download the wrong thing.
    @Test("picks the asset by exact name, not by position")
    func picksAssetByName() async throws {
        let body = Data("""
        {"tag_name":"v0.4.0","assets":[
          {"name":"SomethingElse.zip",
           "browser_download_url":"https://example.com/wrong.zip"},
          {"name":"PRMaster.app.zip",
           "browser_download_url":"https://example.com/right.zip"}
        ]}
        """.utf8)
        let ctx = makeClient([.response(status: 200, body: body)])
        let release = try await ctx.client.fetchLatestRelease()

        #expect(release.assetURL.absoluteString == "https://example.com/right.zip")
    }

    // MARK: failures

    /// A repo that has never been released is the state this app ships in, so it
    /// gets its own case rather than a warning row telling the user something
    /// is broken.
    @Test("a 404 means no release yet, not a failure")
    func noReleaseYet() async throws {
        let ctx = makeClient([.response(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8))])
        await #expect(throws: PRMasterError.noReleaseYet) {
            try await ctx.client.fetchLatestRelease()
        }
    }

    /// A release whose build failed halfway can exist with no asset attached.
    /// Reporting "up to date" would strand the user on an old version forever.
    @Test("a release without the expected asset is an error")
    func assetMissing() async throws {
        let body = Data(#"{"tag_name":"v0.5.0","assets":[]}"#.utf8)
        let ctx = makeClient([.response(status: 200, body: body)])
        await #expect(throws: PRMasterError.releaseAssetMissing) {
            try await ctx.client.fetchLatestRelease()
        }
    }

    @Test("malformed JSON surfaces as a decoding failure")
    func malformedJSON() async throws {
        let ctx = makeClient([.response(status: 200, body: Data("<html>502</html>".utf8))])
        do {
            _ = try await ctx.client.fetchLatestRelease()
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test("an unexpected status names the status code")
    func unexpectedStatus() async throws {
        let ctx = makeClient([.response(status: 503, body: Data())])
        do {
            _ = try await ctx.client.fetchLatestRelease()
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .releaseCheckFailed(let message) = error else {
                Issue.record("expected .releaseCheckFailed, got \(error)")
                return
            }
            #expect(message.contains("503"))
        }
    }

    @Test("transport failures map to network")
    func networkFailure() async throws {
        let ctx = makeClient([.failure(URLError(.notConnectedToInternet))])
        await #expect(throws: PRMasterError.network(URLError(.notConnectedToInternet))) {
            try await ctx.client.fetchLatestRelease()
        }
    }
}

/// New cases join the existing rule that no message may read like an internal
/// diagnostic.
@Suite("Release error messages")
struct ReleaseErrorMessageTests {

    @Test("every release failure has an actionable message", arguments: [
        PRMasterError.noReleaseYet,
        .releaseAssetMissing,
        .releaseCheckFailed("GitHub returned 503"),
        .updateVerificationFailed,
        .updateFailed("could not unpack the archive"),
    ])
    func hasMessage(error: PRMasterError) throws {
        let message = try #require(error.errorDescription)
        #expect(!message.isEmpty)
        #expect(!message.contains("NSURLErrorDomain"))
        #expect(!message.contains("Error Domain"))
    }

    /// A failed integrity check must not read like a transient glitch the user
    /// should shrug at and retry — it is the one case that means the bytes were
    /// not what GitHub said they were.
    @Test("a failed integrity check says the update was not installed")
    func verificationMessageIsUnambiguous() throws {
        let message = try #require(PRMasterError.updateVerificationFailed.errorDescription)
        #expect(message.contains("integrity"))
        #expect(message.contains("not installed"))
    }

    /// Equatable is what lets `#expect(throws:)` name an exact case, so a new
    /// case that falls through to `default` would make those assertions pass
    /// against the wrong error.
    @Test("new cases compare by case, not by default")
    func equatableCoversNewCases() {
        #expect(PRMasterError.noReleaseYet == .noReleaseYet)
        #expect(PRMasterError.releaseAssetMissing == .releaseAssetMissing)
        #expect(PRMasterError.releaseCheckFailed("a") == .releaseCheckFailed("a"))
        #expect(PRMasterError.releaseCheckFailed("a") != .releaseCheckFailed("b"))
        #expect(PRMasterError.noReleaseYet != .releaseAssetMissing)
        #expect(PRMasterError.updateVerificationFailed == .updateVerificationFailed)
        #expect(PRMasterError.updateFailed("a") == .updateFailed("a"))
        #expect(PRMasterError.updateFailed("a") != .updateFailed("b"))
        #expect(PRMasterError.updateVerificationFailed != .updateFailed("a"))
    }
}
