import Foundation
import Observation

public protocol JiraVerifying: Sendable {
    func verify(_ credentials: JiraCredentials) async throws -> String
}

public struct JiraVerifier: JiraVerifying {
    public init() {}

    public func verify(_ credentials: JiraCredentials) async throws -> String {
        try await JiraClient(credentials: credentials).verify()
    }
}

@MainActor
@Observable
public final class JiraAccountStore {

    public var site: String = ""
    public var email: String = ""
    public var apiToken: String = ""

    public private(set) var signInState: JiraSignInState = .idle
    public private(set) var current: JiraCredentials?

    private let credentialStore: any JiraCredentialStoring
    private let verifier: any JiraVerifying

    public var isConfigured: Bool { current != nil }

    public init(
        credentials: any JiraCredentialStoring = JiraCredentialStore(),
        verifier: any JiraVerifying = JiraVerifier()
    ) {
        self.credentialStore = credentials
        self.verifier = verifier
        reload()
    }

    /// The token is deliberately not repopulated: it is write-only from the
    /// form's point of view, so a stored secret never sits in a text field.
    private func reload() {
        current = try? credentialStore.credentials() ?? nil
        site = current?.baseURL.absoluteString ?? ""
        email = current?.email ?? ""
        apiToken = ""
    }

    /// Verifies before storing, so a typo is rejected at the point of entry
    /// rather than surfacing an hour later as a failing poll.
    public func testAndSave() async {
        signInState = .testing

        let candidate: JiraCredentials
        do {
            candidate = try JiraCredentials(baseURL: site, email: email, apiToken: apiToken)
        } catch let error as PRMasterError {
            signInState = .failed(message: JiraSignInState.message(for: error))
            return
        } catch {
            signInState = .failed(message: error.localizedDescription)
            return
        }

        do {
            let name = try await verifier.verify(candidate)
            try credentialStore.save(candidate)
            current = candidate
            apiToken = ""
            signInState = .succeeded(name: name)
        } catch let error as PRMasterError {
            signInState = .failed(message: JiraSignInState.message(for: error))
        } catch {
            signInState = .failed(message: error.localizedDescription)
        }
    }

    public func signOut() {
        try? credentialStore.clear()
        current = nil
        site = ""
        email = ""
        apiToken = ""
        signInState = .idle
    }
}
