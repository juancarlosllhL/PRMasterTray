import Foundation

/// An OpenRouter API key. Printing one never shows it.
public struct OpenRouterKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String

    public init(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PRMasterError.heatmapRefused("no API key entered") }
        value = trimmed
    }

    public var description: String { "OpenRouterKey(redacted)" }
    public var debugDescription: String { description }
}

public protocol OpenRouterKeyStoring: Sendable {
    func key() throws -> OpenRouterKey?
    func save(_ key: OpenRouterKey) throws
    func clear() throws
}

/// PRMaster's own Keychain item, then the environment, then nothing.
public struct OpenRouterKeyStore: OpenRouterKeyStoring {

    public static let keychainService = "com.jcll.PRMaster.openrouter"
    public static let keychainAccount = "openrouter"
    public static let item = Keychain(service: keychainService, account: keychainAccount)

    private let environment: [String: String]
    private let readItem: @Sendable () throws -> String?
    private let writeItem: @Sendable (String) throws -> Void
    private let deleteItem: @Sendable () throws -> Void

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readItem: @escaping @Sendable () throws -> String? = { try OpenRouterKeyStore.item.read() },
        writeItem: @escaping @Sendable (String) throws -> Void = { try OpenRouterKeyStore.item.write($0) },
        deleteItem: @escaping @Sendable () throws -> Void = { try OpenRouterKeyStore.item.delete() }
    ) {
        self.environment = environment
        self.readItem = readItem
        self.writeItem = writeItem
        self.deleteItem = deleteItem
    }

    public func key() throws -> OpenRouterKey? {
        if let stored = try readItem() { return try OpenRouterKey(stored) }
        return try environment["OPENROUTER_API_KEY"].map(OpenRouterKey.init)
    }

    public func save(_ key: OpenRouterKey) throws { try writeItem(key.value) }

    public func clear() throws { try deleteItem() }
}
