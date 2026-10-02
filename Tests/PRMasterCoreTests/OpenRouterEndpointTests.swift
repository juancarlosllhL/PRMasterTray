import Foundation
import Testing
@testable import PRMasterCore

/// The API key travels to whatever this URL names, so a URL that could send it
/// in the clear, or smuggle it elsewhere, is refused before anything is sent.
@Suite("OpenRouter endpoint")
struct OpenRouterEndpointTests {

    @Test("blank means OpenRouter itself")
    func blankIsDefault() throws {
        #expect(try OpenRouterEndpoint("").baseURL.absoluteString == "https://openrouter.ai/api/v1")
        #expect(try OpenRouterEndpoint("   \n").baseURL == OpenRouterEndpoint.default.baseURL)
        #expect(OpenRouterEndpoint.default.isDefault)
    }

    @Test("requests go to systemone under the base, whatever the trailing slash")
    func systemOnePath() throws {
        #expect(OpenRouterEndpoint.default.systemOne.absoluteString == "https://openrouter.ai/api/v1/systemone")
        let proxy = try OpenRouterEndpoint("  https://llm-proxy.corp.example/openrouter/api/v1/ ")
        #expect(proxy.baseURL.absoluteString == "https://llm-proxy.corp.example/openrouter/api/v1")
        #expect(proxy.systemOne.absoluteString == "https://llm-proxy.corp.example/openrouter/api/v1/systemone")
        #expect(!proxy.isDefault)
    }

    @Test("a port is kept")
    func port() throws {
        #expect(try OpenRouterEndpoint("https://proxy.example:8443/v1").systemOne.absoluteString
                == "https://proxy.example:8443/v1/systemone")
    }

    @Test("plain http is allowed only to this machine", arguments: [
        "http://localhost:8080/api/v1", "http://127.0.0.1:4000", "http://[::1]:4000/v1",
    ])
    func loopbackHTTP(raw: String) throws {
        #expect(try OpenRouterEndpoint(raw).systemOne.scheme == "http")
    }

    @Test("URLs that could leak the key or are not URLs at all are refused", arguments: [
        "http://proxy.corp.example/api/v1",
        "ftp://proxy.corp.example/api",
        "proxy.corp.example/api/v1",
        "https://",
        "https:///api/v1",
        "https://user:secret@proxy.corp.example/api/v1",
        "https://user@proxy.corp.example/api/v1",
        "https://proxy.corp.example/api/v1?key=1",
        "https://proxy.corp.example/api/v1#top",
        "https://proxy corp.example/api",
        "not a url",
    ])
    func refused(raw: String) {
        #expect(throws: PRMasterError.self) { try OpenRouterEndpoint(raw) }
    }

    @Test("a refusal says what is wrong with the URL")
    func reasons() {
        func reason(_ raw: String) -> String {
            do {
                _ = try OpenRouterEndpoint(raw)
                return ""
            } catch {
                return error.localizedDescription
            }
        }
        #expect(reason("http://proxy.corp.example").contains("https"))
        #expect(reason("https://a:b@proxy.corp.example").contains("password"))
        #expect(reason("https://proxy.corp.example?x=1").contains("query"))
    }
}
