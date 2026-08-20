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

    /// Whether a values file *declares* the image, rather than merely mentioning
    /// it somewhere.
    ///
    /// Code search is token-based, so an image name matches files that only
    /// contain it as a substring of something else — a real example being
    /// `secretName: clickhouseuser-ch-lec-ai-chat-assistant-credentials` in an
    /// unrelated service, which would otherwise put that service's versions on
    /// this one's rows.
    ///
    /// Three keys count as a declaration, and all three are needed: `appName`
    /// and the image disagree whenever a chart is named in the plural and its
    /// image in the singular, and only the Kargo subscription is present in a
    /// `kargo/values.yaml`.
    public static func declares(image: String, in text: String) -> Bool {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            guard let colon = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[trimmed.startIndex..<colon])
            guard key == "appName" || key == "repositoryName" || key == "imageTag" else { continue }

            let value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: quotes)
            // The tag is a registry path; the name is the last segment of it.
            let named = value.split(separator: "/").last.map(String.init) ?? value
            if named == image { return true }
        }
        return false
    }

    /// Whether Kargo promotes into this app folder at all.
    ///
    /// A decommissioned folder keeps its chart and its values files, so it goes
    /// on declaring the image and goes on naming a `stableVersion` — frozen at
    /// whatever was promoted the day it was switched off. Nothing in the folder
    /// says it is dead, and a version nobody promoted is worse than no version:
    /// it cannot be matched to a release, and one unanswerable region silences
    /// the environment for the live app beside it. The Kargo subscription is the
    /// difference, and the tree listing already in hand carries it.
    public static func isKargoManaged(entries: [TreeEntry]) -> Bool {
        entries.contains { $0.name == "kargo" }
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
