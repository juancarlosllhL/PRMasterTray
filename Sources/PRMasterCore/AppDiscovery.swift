import Foundation

/// One app folder in one deployments repository — the pair that locates the
/// values files Kargo promotes into.
public struct AppLocation: Sendable, Hashable, Codable {
    /// `owner/name` of the deployments repository, e.g. `Lansweeper/assetcortex-deployments`.
    public let deploymentsRepo: String
    /// The app's folder at the root of that repository, e.g. `ai-chat-assistant`.
    public let appPath: String

    public init(deploymentsRepo: String, appPath: String) {
        self.deploymentsRepo = deploymentsRepo
        self.appPath = appPath
    }
}

/// One entry in an app folder, with the oid of its content.
///
/// The oid is what makes a values file skippable: unchanged content means an
/// unchanged promoted version, so a steady-state poll never re-reads the text.
public struct TreeEntry: Sendable, Equatable {
    public let name: String
    public let oid: String

    public init(name: String, oid: String) {
        self.name = name
        self.oid = oid
    }
}

/// One values file worth reading, identified by the oid its text will be cached
/// under.
public struct BlobRequest: Sendable, Hashable {
    public let location: AppLocation
    public let file: String
    public let oid: String

    public init(location: AppLocation, file: String, oid: String) {
        self.location = location
        self.file = file
        self.oid = oid
    }
}

/// Finding which app folders belong to a service repository.
///
/// The mapping cannot be derived from names. `LECAnalyticsAssetsConsumerV2`
/// pushes `lec-analytics-asset-consumer-v2` into the folder
/// `analytics-assets-consumer-v2`, whose chart calls itself
/// `lec-analytics-assets-consumer-v2` — three spellings, no two alike. The image
/// name is the one string that appears verbatim on both sides.
public enum AppDiscovery {

    private static let key = "repository:"
    private static let quotes = CharacterSet(charactersIn: "\"'")

    /// The image names a service repository pushes, in the order they appear.
    ///
    /// The key is nested, so leading whitespace is trimmed before matching
    /// rather than used as the guard.
    public static func imageNames(inCircleCIConfig text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(into: [String]()) { names, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(key),
                      let token = trimmed.dropFirst(key.count)
                          .split(whereSeparator: \.isWhitespace).first
                else { return }
                let name = String(token).trimmingCharacters(in: quotes)
                guard !name.isEmpty, !names.contains(name) else { return }
                names.append(name)
            }
    }

    /// The app folders behind a set of code-search hits.
    ///
    /// `.stages/` holds a rendered copy of every app, one per cluster. Kargo
    /// never writes there, so a hit inside it would name a generated file and
    /// multiply each app by the number of clusters.
    public static func locations(fromSearchPaths paths: [(repo: String, path: String)]) -> [AppLocation] {
        var seen: Set<AppLocation> = []
        return paths.compactMap { hit in
            guard !hit.path.hasPrefix(".stages/"),
                  let app = hit.path.split(separator: "/").first.map(String.init),
                  app.hasSuffix(".yaml") == false
            else { return nil }
            let location = AppLocation(deploymentsRepo: hit.repo, appPath: app)
            return seen.insert(location).inserted ? location : nil
        }
    }
}
