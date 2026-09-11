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
/// Driven through `/usr/bin/security` rather than `SecItem` on purpose. An item
/// created in-process carries a partition list keyed on the app's code hash,
/// which changes with every build and asks for the login password again.
public struct Keychain: Sendable {

    public struct RunResult: Sendable {
        public let stdout: String
        public let exitCode: Int32

        public init(stdout: String, exitCode: Int32) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    public static let tool = "/usr/bin/security"
    static let itemNotFound: Int32 = 44

    let service: String
    let account: String
    private let run: @Sendable ([String], String?) throws -> RunResult

    public init(
        service: String = JiraCredentialStore.keychainService,
        account: String = JiraCredentialStore.keychainAccount,
        run: @escaping @Sendable ([String], String?) throws -> RunResult = Keychain.execute
    ) {
        self.service = service
        self.account = account
        self.run = run
    }

    public static func read() throws -> String? { try Keychain().read() }
    public static func write(_ value: String) throws { try Keychain().write(value) }
    public static func delete() throws { try Keychain().delete() }

    private var locator: [String] { ["-s", service, "-a", account] }

    public func read() throws -> String? {
        let result = try run(["find-generic-password"] + locator + ["-w"], nil)
        if result.exitCode == Self.itemNotFound { return nil }
        guard result.exitCode == 0 else {
            throw PRMasterError.jiraKeychainFailure(status: Int(result.exitCode))
        }

        let printed = result.stdout.hasSuffix("\n")
            ? String(result.stdout.dropLast())
            : result.stdout
        guard let data = Data(base64Encoded: printed),
              let decoded = String(data: data, encoding: .utf8)
        else { return printed }
        return decoded
    }

    /// Replaced rather than updated: an item left by a build that wrote it
    /// in-process cannot be modified without the login password. The value is
    /// an argument because security's prompt reads at most 128 characters.
    public func write(_ value: String) throws {
        try delete()

        let encoded = Data(value.utf8).base64EncodedString()
        let result = try run(["add-generic-password"] + locator + ["-w", encoded], nil)
        guard result.exitCode == 0 else {
            throw PRMasterError.jiraKeychainFailure(status: Int(result.exitCode))
        }
    }

    public func delete() throws {
        let result = try run(["delete-generic-password"] + locator, nil)
        guard result.exitCode == 0 || result.exitCode == Self.itemNotFound else {
            throw PRMasterError.jiraKeychainFailure(status: Int(result.exitCode))
        }
    }

    public static func execute(_ arguments: [String], input: String?) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(
            stdout: String(decoding: data, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}
