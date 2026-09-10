import Foundation

/// Site, email and API token for Jira Cloud, used as HTTP Basic.
///
/// OAuth is not an option: Atlassian's 3LO flow still requires a client secret
/// and no distributable binary can hold one. See the plan for ECO-283.
public struct JiraCredentials: Sendable, Equatable, CustomStringConvertible,
                               CustomDebugStringConvertible {
    public let baseURL: URL
    public let email: String

    /// Not `public`. Nothing outside this module may read it, and neither
    /// description below includes it.
    let apiToken: String

    public init(baseURL: String, email: String, apiToken: String) throws {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)

        var withoutSlash = trimmedURL
        while withoutSlash.hasSuffix("/") { withoutSlash.removeLast() }

        guard withoutSlash.lowercased().hasPrefix("https://"),
              let url = URL(string: withoutSlash),
              url.host?.isEmpty == false
        else {
            throw PRMasterError.jiraInvalidCredentials(
                detail: "The site must be an https:// address, like https://acme.atlassian.net"
            )
        }
        guard trimmedEmail.contains("@") else {
            throw PRMasterError.jiraInvalidCredentials(detail: "That does not look like an email address.")
        }
        guard !trimmedToken.isEmpty else {
            throw PRMasterError.jiraInvalidCredentials(detail: "The API token is empty.")
        }

        self.baseURL = url
        self.email = trimmedEmail
        self.apiToken = trimmedToken
    }

    var basicAuthHeader: String {
        "Basic " + Data("\(email):\(apiToken)".utf8).base64EncodedString()
    }

    public var description: String { "JiraCredentials(\(baseURL.absoluteString), \(email))" }
    public var debugDescription: String { description }
}
