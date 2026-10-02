import Foundation
import Observation

public protocol HeatmapVerifying: Sendable {
    func verify(_ key: OpenRouterKey, at endpoint: OpenRouterEndpoint) async throws
}

public struct JevVerifier: HeatmapVerifying {
    public init() {}

    public func verify(_ key: OpenRouterKey, at endpoint: OpenRouterEndpoint) async throws {
        try await JevClient(key: key, endpoint: endpoint).verify()
    }
}

public enum HeatmapKeyState: Sendable, Equatable {
    case idle, testing, succeeded
    case failed(message: String)

    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@MainActor
@Observable
public final class HeatmapAccountStore {

    /// Write-only from the form's point of view, so a stored secret never sits in a text field.
    public var token = ""
    /// Blank for OpenRouter itself, or a proxy's base URL.
    public var apiURL = ""
    public private(set) var state: HeatmapKeyState = .idle
    public private(set) var current: OpenRouterKey?
    /// Nil when the saved URL no longer passes the checks: scoring stays off rather than going to openrouter.ai.
    public private(set) var endpoint: OpenRouterEndpoint?

    public var isConfigured: Bool { current != nil }

    /// Checked as it is typed, so a bad URL is explained before anything is sent.
    public var urlProblem: String? {
        do {
            _ = try OpenRouterEndpoint(apiURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public var scorer: BlockScoring? {
        guard let current, let endpoint else { return nil }
        return JevClient(key: current, endpoint: endpoint)
    }

    private let keys: any OpenRouterKeyStoring
    private let verifier: any HeatmapVerifying
    private let preferences: PreferenceStoring

    public init(
        keys: any OpenRouterKeyStoring = OpenRouterKeyStore(), verifier: any HeatmapVerifying = JevVerifier(),
        preferences: PreferenceStoring = UserDefaultsPreferences()
    ) {
        self.keys = keys
        self.verifier = verifier
        self.preferences = preferences
        current = try? keys.key() ?? nil
        apiURL = preferences.heatmapBaseURL() ?? ""
        endpoint = try? OpenRouterEndpoint(apiURL)
    }

    /// Verifies key and URL together before storing either, so a typo is caught here
    /// rather than as a window of failed files. An empty key field reuses the saved key.
    public func testAndSave() async {
        state = .testing
        do {
            let target = try OpenRouterEndpoint(apiURL)
            let candidate = try token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && current != nil
                ? current! : OpenRouterKey(token)
            try await verifier.verify(candidate, at: target)
            if candidate != current { try keys.save(candidate) }
            preferences.setHeatmapBaseURL(target.isDefault ? nil : target.baseURL.absoluteString)
            current = candidate
            endpoint = target
            apiURL = target.isDefault ? "" : target.baseURL.absoluteString
            token = ""
            state = .succeeded
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    public func signOut() {
        try? keys.clear()
        current = nil
        token = ""
        state = .idle
    }
}
