import Foundation
import Testing
@testable import PRMasterCore

/// Exercises the real `SecItem` calls, which every other test stubs out.
///
/// Uses a throwaway service name so the user's own saved sign-in is never
/// touched, and deletes what it wrote.
@Suite("Keychain round trip", .serialized)
struct KeychainTests {

    private static let service = "com.jcll.PRMaster.tests"

    private func keychain(_ account: String) -> Keychain {
        Keychain(service: Self.service, account: account)
    }

    @Test("a missing item reads as nil rather than throwing")
    func missingReadsAsNil() throws {
        let subject = keychain("absent-\(UUID().uuidString)")
        #expect(try subject.read() == nil)
    }

    @Test("what is written comes back")
    func writeThenRead() throws {
        let subject = keychain("round-trip-\(UUID().uuidString)")
        defer { try? subject.delete() }

        try subject.write(#"{"hello":"world"}"#)
        #expect(try subject.read() == #"{"hello":"world"}"#)
    }

    /// The write path takes SecItemUpdate first and only falls back to
    /// SecItemAdd on errSecItemNotFound, so overwriting is the branch most
    /// likely to be wrong.
    @Test("writing twice updates rather than duplicating")
    func writeTwiceUpdates() throws {
        let subject = keychain("overwrite-\(UUID().uuidString)")
        defer { try? subject.delete() }

        try subject.write("first")
        try subject.write("second")
        #expect(try subject.read() == "second")
    }

    @Test("deleting removes it")
    func deleteRemoves() throws {
        let subject = keychain("delete-\(UUID().uuidString)")
        try subject.write("doomed")
        try subject.delete()
        #expect(try subject.read() == nil)
    }

    /// `clear()` is called on sign-out whether or not anything was stored.
    @Test("deleting something absent is not an error")
    func deleteAbsentIsFine() throws {
        try keychain("never-existed-\(UUID().uuidString)").delete()
    }

    @Test("accounts do not read each other's values")
    func accountsAreIsolated() throws {
        let one = keychain("iso-a-\(UUID().uuidString)")
        let two = keychain("iso-b-\(UUID().uuidString)")
        defer { try? one.delete(); try? two.delete() }

        try one.write("mine")
        #expect(try two.read() == nil)
        #expect(try one.read() == "mine")
    }

    /// The full store over the real Keychain, not a stubbed one.
    @Test("the credential store round-trips through the real Keychain")
    func storeRoundTripsForReal() throws {
        let account = "store-\(UUID().uuidString)"
        let subject = keychain(account)
        defer { try? subject.delete() }

        let store = JiraCredentialStore(
            environment: [:],
            readItem: { try subject.read() },
            writeItem: { try subject.write($0) },
            deleteItem: { try subject.delete() }
        )
        let original = try JiraCredentials(
            baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "tok"
        )

        try store.save(original)
        #expect(try store.credentials() == original)

        try store.clear()
        #expect(try store.credentials() == nil)
    }
}
