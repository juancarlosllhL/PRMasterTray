import Foundation

/// The two environments a change passes through on its way to customers.
public enum DeployEnvironment: Sendable, Equatable {
    case staging
    case production

    /// Apps pinned to the central clusters spell the same two environments
    /// `cst` and `cpr`. Anything else is left unrecognised rather than guessed:
    /// naming the wrong environment is worse than naming none.
    static func from(code: String) -> DeployEnvironment? {
        switch code {
        case "stg", "cst": return .staging
        case "prd", "cpr": return .production
        default: return nil
        }
    }
}

/// One `values.<env>.<region>.yaml` in a deployments repository — the file
/// Kargo commits a promoted version into.
public struct PromotionFile: Sendable, Equatable {
    public let environment: DeployEnvironment
    public let region: String

    public init(environment: DeployEnvironment, region: String) {
        self.environment = environment
        self.region = region
    }

    /// Only the region-qualified files are promotions. `values.yaml` carries a
    /// `stableVersion: 0.0.0` placeholder, so rejecting it here is what keeps
    /// version zero from ever reaching the rest of the app.
    public static func parse(name: String) -> PromotionFile? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              parts[0] == "values",
              parts[3] == "yaml",
              !parts[2].isEmpty,
              let environment = DeployEnvironment.from(code: parts[1])
        else { return nil }
        return PromotionFile(environment: environment, region: parts[2])
    }

    private static let key = "stableVersion:"
    private static let quotes = CharacterSet(charactersIn: "\"'")

    /// Anchored at column 0 and stopping at the first whitespace: these files
    /// argue about versions in prose, and a mention inside a comment or a
    /// sub-chart's own key must never read as the promoted version.
    public static func stableVersion(in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix(key) {
            guard let token = line.dropFirst(key.count).split(whereSeparator: \.isWhitespace).first
            else { return nil }
            let version = String(token).trimmingCharacters(in: quotes)
            return version.isEmpty ? nil : version
        }
        return nil
    }
}
