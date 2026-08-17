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

/// The version one region of one environment is running.
public struct PromotedVersion: Sendable, Equatable {
    public let file: PromotionFile
    public let version: String

    public init(file: PromotionFile, version: String) {
        self.file = file
        self.version = version
    }
}

/// What one environment is running, across all of its regions.
public struct EnvironmentPromotion: Sendable, Equatable {
    public let environment: DeployEnvironment
    /// Every region's version, deduplicated. Kept whole rather than reduced to
    /// `displayVersion` so that whether a change reached this environment can be
    /// answered per region, without inheriting an ordering it must not depend on.
    public let versions: [String]

    public init(environment: DeployEnvironment, versions: [String]) {
        self.environment = environment
        self.versions = versions
    }

    public var regionsAgree: Bool { versions.count <= 1 }

    /// The lowest version, because a rollout that has reached one region has not
    /// reached the environment. Ordered numerically: sorted as strings, `1.10.0`
    /// lands below `1.9.0`.
    public var displayVersion: String? {
        versions.min { ReleaseVersion.isNewer($1, than: $0) }
    }

    /// Staging first, so a row reads in the order a change actually travels. An
    /// environment nobody promoted to is left out rather than carried as empty.
    public static func collapse(_ promoted: [PromotedVersion]) -> [EnvironmentPromotion] {
        [DeployEnvironment.staging, .production].compactMap { environment in
            let versions = promoted
                .filter { $0.file.environment == environment }
                .reduce(into: [String]()) { unique, entry in
                    if !unique.contains(entry.version) { unique.append(entry.version) }
                }
            guard !versions.isEmpty else { return nil }
            return EnvironmentPromotion(environment: environment, versions: versions)
        }
    }
}
