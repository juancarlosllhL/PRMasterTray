import Foundation
import Testing
@testable import PRMasterCore

@Suite("JiraCredentials validation")
struct JiraCredentialValidationTests {

    @Test("a well-formed triple is accepted")
    func wellFormedIsAccepted() throws {
        let creds = try JiraCredentials(
            baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "tok"
        )
        #expect(creds.email == "a@b.com")
    }

    /// A trailing slash would double up against the request path.
    @Test("a trailing slash is normalised away", arguments: [
        "https://acme.atlassian.net/",
        "https://acme.atlassian.net//",
        "  https://acme.atlassian.net/  ",
    ])
    func trailingSlashNormalised(input: String) throws {
        let creds = try JiraCredentials(baseURL: input, email: "a@b.com", apiToken: "tok")
        #expect(creds.baseURL.absoluteString == "https://acme.atlassian.net")
    }

    @Test("bad input is rejected", arguments: [
        ("http://acme.atlassian.net", "a@b.com", "tok"),
        ("ftp://acme.atlassian.net", "a@b.com", "tok"),
        ("not a url at all", "a@b.com", "tok"),
        ("", "a@b.com", "tok"),
        ("https://acme.atlassian.net", "no-at-sign", "tok"),
        ("https://acme.atlassian.net", "", "tok"),
        ("https://acme.atlassian.net", "a@b.com", ""),
        ("https://acme.atlassian.net", "a@b.com", "   "),
    ])
    func badInputRejected(baseURL: String, email: String, token: String) {
        #expect(throws: (any Error).self) {
            try JiraCredentials(baseURL: baseURL, email: email, apiToken: token)
        }
    }

    /// Basic auth is `base64(email:token)`, the shape verified against the real
    /// site. Pinned so a change to the header cannot pass unnoticed.
    @Test("the basic auth header matches a known pair")
    func basicHeaderIsCorrect() throws {
        let creds = try JiraCredentials(
            baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "s3cret"
        )
        let expected = Data("a@b.com:s3cret".utf8).base64EncodedString()
        #expect(creds.basicAuthHeader == "Basic \(expected)")
    }

    /// The token must not leak through any of the automatic descriptions, which
    /// is how a credential ends up in a log nobody meant to write.
    @Test("no description exposes the token")
    func tokenIsNotDescribed() throws {
        let creds = try JiraCredentials(
            baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "s3cretV4lue"
        )
        #expect(!String(describing: creds).contains("s3cretV4lue"))
        #expect(!String(reflecting: creds).contains("s3cretV4lue"))
    }
}

@Suite("Jira error equality")
struct JiraErrorEqualityTests {

    /// `PRMasterError`'s `==` is hand-written with a `default: return false`,
    /// so a case added without a branch compares unequal to itself and every
    /// `#expect(error == .someCase)` silently passes nothing.
    @Test("the new cases equal themselves")
    func newCasesAreEqual() {
        #expect(PRMasterError.jiraUnauthorized == .jiraUnauthorized)
        #expect(PRMasterError.jiraKeychainFailure(status: -25300)
                == .jiraKeychainFailure(status: -25300))
        #expect(PRMasterError.jiraInvalidCredentials(detail: "x")
                == .jiraInvalidCredentials(detail: "x"))
    }

    @Test("they still differ on their payload")
    func payloadsDiffer() {
        #expect(PRMasterError.jiraKeychainFailure(status: -1)
                != .jiraKeychainFailure(status: -2))
        #expect(PRMasterError.jiraInvalidCredentials(detail: "x")
                != .jiraInvalidCredentials(detail: "y"))
        #expect(PRMasterError.jiraUnauthorized != .jiraInvalidCredentials(detail: "x"))
    }
}

@Suite("JiraCredentialStore resolution")
struct JiraCredentialStoreTests {

    private static let json = """
        {"baseUrl":"https://acme.atlassian.net","email":"a@b.com","apiToken":"tok"}
        """

    private func store(
        keychain: String? = nil,
        env: [String: String] = [:]
    ) -> JiraCredentialStore {
        JiraCredentialStore(
            environment: env,
            readItem: { keychain },
            writeItem: { _ in },
            deleteItem: {}
        )
    }

    @Test("the keychain item wins")
    func keychainWins() throws {
        let resolved = try store(
            keychain: Self.json,
            env: [
                "JIRA_BASE_URL": "https://other.atlassian.net",
                "JIRA_EMAIL": "z@z.com",
                "JIRA_API_TOKEN": "other",
            ]
        ).credentials()
        #expect(resolved?.baseURL.absoluteString == "https://acme.atlassian.net")
    }

    @Test("the environment is used when the keychain is empty")
    func environmentIsFallback() throws {
        let resolved = try store(env: [
            "JIRA_BASE_URL": "https://env.atlassian.net",
            "JIRA_EMAIL": "z@z.com",
            "JIRA_API_TOKEN": "envtok",
        ]).credentials()
        #expect(resolved?.baseURL.absoluteString == "https://env.atlassian.net")
    }

    /// A half-set environment is not a credential, and must not be treated as
    /// a broken one either.
    @Test("a partial environment is ignored", arguments: [
        ["JIRA_BASE_URL": "https://env.atlassian.net"],
        ["JIRA_EMAIL": "z@z.com"],
        ["JIRA_BASE_URL": "https://env.atlassian.net", "JIRA_EMAIL": "z@z.com"],
    ])
    func partialEnvironmentIgnored(env: [String: String]) throws {
        #expect(try store(env: env).credentials() == nil)
    }

    /// Not configured is not a failure, so it must not throw.
    @Test("nothing anywhere yields nil rather than an error")
    func nothingYieldsNil() throws {
        #expect(try store().credentials() == nil)
    }

    @Test("malformed stored JSON is rejected", arguments: [
        "not json at all",
        "{}",
        "[]",
        #"{"baseUrl":"https://acme.atlassian.net"}"#,
        #"{"baseUrl":"http://acme.atlassian.net","email":"a@b.com","apiToken":"t"}"#,
    ])
    func malformedJSONRejected(raw: String) {
        #expect(throws: (any Error).self) {
            try store(keychain: raw).credentials()
        }
    }

    @Test("saving writes the item and clearing deletes it")
    func saveAndClear() throws {
        final class Box: @unchecked Sendable {
            var written: String?
            var deleted = false
        }
        let box = Box()
        let store = JiraCredentialStore(
            environment: [:],
            readItem: { nil },
            writeItem: { box.written = $0 },
            deleteItem: { box.deleted = true }
        )

        try store.save(JiraCredentials(
            baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "tok"
        ))
        #expect(box.written?.contains("acme.atlassian.net") == true)

        try store.clear()
        #expect(box.deleted)
    }

    /// A round trip through the store's own serialisation, so save and load
    /// cannot drift apart.
    @Test("what is saved is what is read back")
    func roundTrips() throws {
        final class Box: @unchecked Sendable { var written: String? }
        let box = Box()
        let writing = JiraCredentialStore(
            environment: [:], readItem: { nil }, writeItem: { box.written = $0 }, deleteItem: {}
        )
        let original = try JiraCredentials(
            baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "tok"
        )
        try writing.save(original)

        let reading = JiraCredentialStore(
            environment: [:], readItem: { box.written }, writeItem: { _ in }, deleteItem: {}
        )
        #expect(try reading.credentials() == original)
    }
}
