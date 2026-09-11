import Foundation

public protocol JiraCredentialStoring: Sendable {
    func credentials() throws -> JiraCredentials?
    func save(_ credentials: JiraCredentials) throws
    func clear() throws
}

/// PRMaster's own Keychain item, then the environment, then nothing.
///
/// No other tool's storage is read at any point: an earlier draft borrowed one
/// and it only ever worked on a single machine.
public struct JiraCredentialStore: JiraCredentialStoring {

    public static let keychainService = "com.jcll.PRMaster.jira"
    public static let keychainAccount = "jira"

    private let environment: [String: String]
    private let readItem: @Sendable () throws -> String?
    private let writeItem: @Sendable (String) throws -> Void
    private let deleteItem: @Sendable () throws -> Void

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readItem: @escaping @Sendable () throws -> String? = Keychain.read,
        writeItem: @escaping @Sendable (String) throws -> Void = Keychain.write,
        deleteItem: @escaping @Sendable () throws -> Void = Keychain.delete
    ) {
        self.environment = environment
        self.readItem = readItem
        self.writeItem = writeItem
        self.deleteItem = deleteItem
    }

    private struct Stored: Codable {
        let baseUrl: String
        let email: String
        let apiToken: String
    }

    /// `nil` means not configured, which is not a failure. A throw means the
    /// stored value is there but unusable, which is.
    public func credentials() throws -> JiraCredentials? {
        if let raw = try readItem() {
            guard let data = raw.data(using: .utf8),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data)
            else {
                throw PRMasterError.jiraInvalidCredentials(
                    detail: "The saved Jira sign-in could not be read. Sign in again."
                )
            }
            return try JiraCredentials(
                baseURL: stored.baseUrl, email: stored.email, apiToken: stored.apiToken
            )
        }

        guard let baseURL = environment["JIRA_BASE_URL"],
              let email = environment["JIRA_EMAIL"],
              let token = environment["JIRA_API_TOKEN"]
        else { return nil }

        return try JiraCredentials(baseURL: baseURL, email: email, apiToken: token)
    }

    public func save(_ credentials: JiraCredentials) throws {
        let stored = Stored(
            baseUrl: credentials.baseURL.absoluteString,
            email: credentials.email,
            apiToken: credentials.apiToken
        )
        try writeItem(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self))
    }

    public func clear() throws {
        try deleteItem()
    }
}

/// A generic password in the login keychain, holding the JSON above.
///
/// Service and account are parameters so a test can exercise the real SecItem
/// calls against its own throwaway item rather than the user's.
public struct Keychain: Sendable {

    let service: String
    let account: String

    public init(
        service: String = JiraCredentialStore.keychainService,
        account: String = JiraCredentialStore.keychainAccount
    ) {
        self.service = service
        self.account = account
    }

    public static func read() throws -> String? { try Keychain().read() }
    public static func write(_ value: String) throws { try Keychain().write(value) }
    public static func delete() throws { try Keychain().delete() }

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw PRMasterError.jiraKeychainFailure(status: Int(status))
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String) throws {
        let data = Data(value.utf8)

        let update = SecItemUpdate(
            base as CFDictionary, [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        if update != errSecItemNotFound {
            throw PRMasterError.jiraKeychainFailure(status: Int(update))
        }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let add = SecItemAdd(insert as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw PRMasterError.jiraKeychainFailure(status: Int(add))
        }
    }

    public func delete() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PRMasterError.jiraKeychainFailure(status: Int(status))
        }
    }
}
