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
public enum Keychain {

    public static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: JiraCredentialStore.keychainService,
            kSecAttrAccount as String: JiraCredentialStore.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw PRMasterError.jiraKeychainFailure(status: Int(status))
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func write(_ value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: JiraCredentialStore.keychainService,
            kSecAttrAccount as String: JiraCredentialStore.keychainAccount,
        ]
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

    public static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: JiraCredentialStore.keychainService,
            kSecAttrAccount as String: JiraCredentialStore.keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PRMasterError.jiraKeychainFailure(status: Int(status))
        }
    }
}
