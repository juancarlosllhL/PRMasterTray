import Foundation
import Testing
@testable import PRMasterCore

private final class MemoryItem: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private(set) var writes = 0

    init(_ value: String? = nil) { self.value = value }

    func read() -> String? { lock.withLock { value } }
    func write(_ new: String) { lock.withLock { value = new; writes += 1 } }
    func delete() { lock.withLock { value = nil } }

    func store(environment: [String: String] = [:]) -> OpenRouterKeyStore {
        OpenRouterKeyStore(environment: environment, readItem: read, writeItem: write, deleteItem: delete)
    }
}

private final class StubVerifier: HeatmapVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<Void, PRMasterError>
    private var checks: [(key: String, url: String)] = []

    init(result: Result<Void, PRMasterError>) { self.result = result }

    var calls: [(key: String, url: String)] { lock.withLock { checks } }

    func verify(_ key: OpenRouterKey, at endpoint: OpenRouterEndpoint) async throws {
        lock.withLock { checks.append((key.value, endpoint.systemOne.absoluteString)) }
        try result.get()
    }
}

/// The key is the one secret this feature adds, and the moment it is saved is
/// the moment diff text starts leaving the machine.
@Suite("Heatmap account")
@MainActor
struct HeatmapAccountStoreTests {

    private func make(
        _ item: MemoryItem = MemoryItem(), verify: Result<Void, PRMasterError> = .success(()),
        preferences: MemoryPreferences = MemoryPreferences(), verifier: StubVerifier? = nil
    ) -> HeatmapAccountStore {
        HeatmapAccountStore(keys: item.store(), verifier: verifier ?? StubVerifier(result: verify), preferences: preferences)
    }

    @Test("a key that works is saved, and the field is emptied")
    func goodKeySaves() async throws {
        let item = MemoryItem()
        let store = make(item)
        store.token = "  sk-or-good \n"
        await store.testAndSave()
        #expect(store.state == .succeeded)
        #expect(store.isConfigured)
        #expect(store.token.isEmpty)
        #expect(try item.store().key()?.value == "sk-or-good")
    }

    @Test("a key OpenRouter rejects is not saved, and says why")
    func rejectedKeySavesNothing() async {
        let item = MemoryItem()
        let store = make(item, verify: .failure(.heatmapUnauthorized))
        store.token = "sk-or-bad"
        await store.testAndSave()
        #expect(store.state == .failed(message: PRMasterError.heatmapUnauthorized.localizedDescription))
        #expect(!store.isConfigured)
        #expect(item.writes == 0)
    }

    @Test("an empty field is refused before anything is sent")
    func emptyKey() async {
        let item = MemoryItem()
        let store = make(item)
        store.token = "   "
        await store.testAndSave()
        #expect(store.state.failureMessage != nil)
        #expect(item.writes == 0)
    }

    @Test("signing out forgets the key")
    func signOut() async throws {
        let item = MemoryItem("sk-or-saved")
        let store = make(item)
        #expect(store.isConfigured)
        store.signOut()
        #expect(!store.isConfigured)
        #expect(try item.store().key() == nil)
    }

    @Test("a saved key is never put back into the form")
    func notRepopulated() {
        let store = make(MemoryItem("sk-or-saved"))
        #expect(store.isConfigured)
        #expect(store.token.isEmpty)
    }

    @Test("with nothing saved, OPENROUTER_API_KEY is used")
    func environmentFallback() throws {
        let key = try MemoryItem().store(environment: ["OPENROUTER_API_KEY": "sk-or-env"]).key()
        #expect(key?.value == "sk-or-env")
    }

    @Test("the Keychain wins over the environment")
    func keychainFirst() throws {
        let key = try MemoryItem("sk-or-saved").store(environment: ["OPENROUTER_API_KEY": "sk-or-env"]).key()
        #expect(key?.value == "sk-or-saved")
    }

    @Test("the key never shows up when printed or logged")
    func notInDescriptions() throws {
        let key = try OpenRouterKey("sk-or-secret")
        #expect(!String(describing: key).contains("secret"))
        #expect(!String(reflecting: key).contains("secret"))
        #expect(!"\(key)".contains("secret"))
    }

    @Test("the key lives under PRMaster's own OpenRouter Keychain item")
    func keychainItem() {
        #expect(OpenRouterKeyStore.keychainService == "com.jcll.PRMaster.openrouter")
        #expect(OpenRouterKeyStore.keychainService != JiraCredentialStore.keychainService)
    }

    @Test("a proxy URL is tested with the key, then saved, and review windows use it")
    func customURLSaved() async throws {
        let preferences = MemoryPreferences()
        let verifier = StubVerifier(result: .success(()))
        let store = make(preferences: preferences, verifier: verifier)
        store.token = "sk-or-good"
        store.apiURL = " https://llm-proxy.corp.example/api/v1/ "
        await store.testAndSave()
        #expect(store.state == .succeeded)
        #expect(verifier.calls.map(\.url) == ["https://llm-proxy.corp.example/api/v1/systemone"])
        #expect(preferences.heatmapBaseURL() == "https://llm-proxy.corp.example/api/v1")
        #expect(store.apiURL == "https://llm-proxy.corp.example/api/v1")
        #expect(store.endpoint?.systemOne.absoluteString == "https://llm-proxy.corp.example/api/v1/systemone")
        #expect(store.scorer != nil)
    }

    @Test("a URL that fails the checks is refused before the key is sent anywhere")
    func invalidURLNeverSent() async {
        let verifier = StubVerifier(result: .success(()))
        let item = MemoryItem()
        let store = make(item, verifier: verifier)
        store.token = "sk-or-good"
        store.apiURL = "http://llm-proxy.corp.example/api/v1"
        await store.testAndSave()
        #expect(store.state.failureMessage?.contains("https") == true)
        #expect(verifier.calls.isEmpty)
        #expect(item.writes == 0)
    }

    @Test("with a key saved, the URL can change without typing the key again")
    func urlOnlyChange() async {
        let preferences = MemoryPreferences()
        let verifier = StubVerifier(result: .success(()))
        let store = make(MemoryItem("sk-or-saved"), preferences: preferences, verifier: verifier)
        store.apiURL = "https://llm-proxy.corp.example/v1"
        await store.testAndSave()
        #expect(store.state == .succeeded)
        #expect(verifier.calls.map(\.key) == ["sk-or-saved"])
        #expect(preferences.heatmapBaseURL() == "https://llm-proxy.corp.example/v1")
    }

    @Test("a URL that fails its test leaves the saved one in use")
    func failedTestKeepsURL() async {
        let preferences = MemoryPreferences()
        preferences.setHeatmapBaseURL("https://old-proxy.corp.example/v1")
        let store = make(MemoryItem("sk-or-saved"), verify: .failure(.heatmapUnavailable(status: nil)), preferences: preferences)
        store.apiURL = "https://new-proxy.corp.example/v1"
        await store.testAndSave()
        #expect(store.state.failureMessage != nil)
        #expect(preferences.heatmapBaseURL() == "https://old-proxy.corp.example/v1")
        #expect(store.endpoint?.baseURL.absoluteString == "https://old-proxy.corp.example/v1")
    }

    @Test("blank goes back to OpenRouter and forgets the proxy")
    func blankResets() async {
        let preferences = MemoryPreferences()
        preferences.setHeatmapBaseURL("https://old-proxy.corp.example/v1")
        let store = make(MemoryItem("sk-or-saved"), preferences: preferences)
        #expect(store.apiURL == "https://old-proxy.corp.example/v1")
        store.apiURL = ""
        await store.testAndSave()
        #expect(preferences.heatmapBaseURL() == nil)
        #expect(store.endpoint == .default)
    }

    @Test("a stored URL that no longer passes the checks turns scoring off rather than falling back to openrouter.ai")
    func badStoredURL() {
        let preferences = MemoryPreferences()
        preferences.setHeatmapBaseURL("http://proxy.corp.example")
        let store = make(MemoryItem("sk-or-saved"), preferences: preferences)
        #expect(store.endpoint == nil)
        #expect(store.scorer == nil)
    }

    @Test("a problem with the URL shows while it is typed, and clears once it is fixed")
    func urlProblemLive() {
        let store = make()
        #expect(store.urlProblem == nil)
        store.apiURL = "https://user:pw@proxy.corp.example"
        #expect(store.urlProblem?.contains("password") == true)
        store.apiURL = "https://proxy.corp.example/v1"
        #expect(store.urlProblem == nil)
    }

    /// Experimental and sends code to a third party, so nobody gets it without asking for it.
    @Test("the heatmap is off by default and the switch is remembered")
    func enabledPreference() {
        let preferences = MemoryPreferences()
        let appearance = AppearanceStore(preferences: preferences)
        #expect(!appearance.heatmapEnabled)
        #expect(!UserDefaultsPreferences(defaults: UserDefaults(suiteName: "heatmap-default-\(UUID())")!).heatmapEnabled())
        appearance.heatmapEnabled = true
        #expect(preferences.heatmapEnabled())
        #expect(AppearanceStore(preferences: preferences).heatmapEnabled)
    }
}
