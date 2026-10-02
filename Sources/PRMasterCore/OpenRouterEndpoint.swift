import Foundation

/// Where System One requests go: OpenRouter itself, or a proxy in front of it.
public struct OpenRouterEndpoint: Sendable, Equatable {

    public static let `default` = OpenRouterEndpoint(checked: URL(string: "https://openrouter.ai/api/v1")!)
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    public let baseURL: URL

    public var systemOne: URL { baseURL.appendingPathComponent("systemone") }
    public var isDefault: Bool { self == .default }

    private init(checked baseURL: URL) { self.baseURL = baseURL }

    /// Blank means OpenRouter. The key is sent wherever this points, so nothing that could leak it passes.
    public init(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .default
            return
        }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            throw Self.invalid("That isn't a URL. It should look like https://proxy.example/api/v1.")
        }
        guard let host = components.host, !host.isEmpty else {
            throw Self.invalid("The URL needs a host, like https://proxy.example/api/v1.")
        }
        guard scheme == "https" || (scheme == "http" && Self.loopbackHosts.contains(host.lowercased())) else {
            throw Self.invalid("Use https://. Plain http is allowed only for localhost.")
        }
        guard components.user == nil, components.password == nil else {
            throw Self.invalid("Leave the user name and password out of the URL.")
        }
        guard components.query == nil, components.fragment == nil else {
            throw Self.invalid("Leave the query and the # part out of the URL.")
        }
        var cleaned = components
        while cleaned.path.hasSuffix("/") { cleaned.path.removeLast() }
        guard let url = cleaned.url else { throw Self.invalid("That isn't a URL.") }
        baseURL = url
    }

    private static func invalid(_ reason: String) -> PRMasterError { .heatmapInvalidURL(reason) }
}
