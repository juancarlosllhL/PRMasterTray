import Foundation

/// A release of PRMaster itself, as published on GitHub.
///
/// Distinct from everything named "update" elsewhere in this package: those all
/// concern bringing a *pull request branch* up to date. This is the app
/// replacing its own bundle.
public struct AppRelease: Sendable, Equatable {
    /// The git tag, as GitHub reports it — conventionally `vX.Y.Z`.
    public let tag: String
    /// `tag` without its `v`, which is the form that compares against
    /// `CFBundleShortVersionString`. Derived rather than passed so no caller
    /// can supply a version that disagrees with the tag.
    public let version: String
    public let assetURL: URL
    /// The asset's sha256 as GitHub reports it, `sha256:`-prefixed. Optional
    /// because the field is absent on assets uploaded before mid-2025; the
    /// installer refuses to run without it rather than skipping the check.
    public let sha256: String?

    public init(tag: String, assetURL: URL, sha256: String?) {
        self.tag = tag
        self.version = ReleaseVersion.strip(tag)
        self.assetURL = assetURL
        self.sha256 = sha256
    }
}

/// Version-string handling for release tags.
public enum ReleaseVersion {

    /// Drops the conventional `v` from a release tag.
    public static func strip(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Whether `remote` is a later version than `local`.
    ///
    /// Compared component-wise as integers, never as strings: `"1.10.0"` sorts
    /// *below* `"1.9.0"` lexicographically, and 1.9 → 1.10 is the first bump
    /// where a string compare would silently stop offering updates.
    ///
    /// A missing component counts as zero, so `1.1` and `1.1.0` are the same
    /// version. A component that is not a number also counts as zero, which is
    /// what keeps a tag like `latest` or `nightly` from presenting itself as an
    /// upgrade over a real version.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = components(of: remote)
        let localParts = components(of: local)

        for index in 0..<max(remoteParts.count, localParts.count) {
            let mine = index < remoteParts.count ? remoteParts[index] : 0
            let theirs = index < localParts.count ? localParts[index] : 0
            if mine != theirs { return mine > theirs }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
