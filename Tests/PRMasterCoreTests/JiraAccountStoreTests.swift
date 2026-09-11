import Foundation
import Testing
@testable import PRMasterCore

private final class SpyStore: JiraCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: JiraCredentials?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(stored: JiraCredentials? = nil) { self.stored = stored }

    func credentials() throws -> JiraCredentials? { lock.withLock { stored } }
    func save(_ credentials: JiraCredentials) throws {
        lock.withLock { stored = credentials; saveCount += 1 }
    }
    func clear() throws { lock.withLock { stored = nil; clearCount += 1 } }
}

private struct StubVerifier: JiraVerifying, Sendable {
    let result: Result<String, PRMasterError>
    func verify(_ credentials: JiraCredentials) async throws -> String { try result.get() }
}

@Suite("JiraAccountStore")
@MainActor
struct JiraAccountStoreTests {

    private func make(
        stored: JiraCredentials? = nil,
        verify: Result<String, PRMasterError> = .success("Ada Lovelace")
    ) -> (JiraAccountStore, SpyStore) {
        let spy = SpyStore(stored: stored)
        let store = JiraAccountStore(credentials: spy, verifier: StubVerifier(result: verify))
        return (store, spy)
    }

    @Test("a good sign-in saves and names the user")
    func goodSignInSaves() async {
        let (store, spy) = make()
        store.site = "https://acme.atlassian.net"
        store.email = "a@b.com"
        store.apiToken = "tok"

        await store.testAndSave()

        #expect(store.signInState.succeededName == "Ada Lovelace")
        #expect(spy.saveCount == 1)
        #expect(store.isConfigured)
    }

    /// A typo must be rejected at the point of entry, not stored and then
    /// surfaced an hour later as a failing poll.
    @Test("a rejected sign-in saves nothing")
    func rejectedSignInSavesNothing() async {
        let (store, spy) = make(verify: .failure(.jiraUnauthorized))
        store.site = "https://acme.atlassian.net"
        store.email = "a@b.com"
        store.apiToken = "wrong"

        await store.testAndSave()

        #expect(spy.saveCount == 0)
        #expect(store.signInState.failureMessage != nil)
        #expect(!store.isConfigured)
    }

    /// Malformed input never reaches the network at all.
    @Test("invalid input fails before verifying", arguments: [
        ("http://acme.atlassian.net", "a@b.com", "tok"),
        ("https://acme.atlassian.net", "nope", "tok"),
        ("https://acme.atlassian.net", "a@b.com", ""),
    ])
    func invalidInputFailsEarly(site: String, email: String, token: String) async {
        let (store, spy) = make()
        store.site = site
        store.email = email
        store.apiToken = token

        await store.testAndSave()

        #expect(spy.saveCount == 0)
        #expect(store.signInState.failureMessage != nil)
    }

    @Test("signing out clears the stored item, not just the form")
    func signOutClears() throws {
        let existing = try JiraCredentials(
            baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "tok"
        )
        let (store, spy) = make(stored: existing)
        #expect(store.isConfigured)

        store.signOut()

        #expect(spy.clearCount == 1)
        #expect(!store.isConfigured)
        #expect(store.apiToken.isEmpty)
        #expect(store.signInState == .idle)
    }

    /// The site and email come back so the form is not blank on reopening,
    /// but the token never does.
    @Test("an existing sign-in repopulates the site and email but never the token")
    func existingRepopulatesWithoutToken() throws {
        let existing = try JiraCredentials(
            baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "s3cret"
        )
        let (store, _) = make(stored: existing)

        #expect(store.site == "https://acme.atlassian.net")
        #expect(store.email == "a@b.com")
        #expect(store.apiToken.isEmpty)
    }

    @Test("nothing stored means not configured")
    func nothingStoredIsUnconfigured() {
        let (store, _) = make()
        #expect(!store.isConfigured)
        #expect(store.signInState == .idle)
    }
}
