import Foundation
import Testing
@testable import PRMasterCore

/// The version comparison decides whether the app offers to replace itself, so
/// getting it wrong is either an update the user never sees or a loop that
/// offers the same version forever.
@Suite("Release version")
struct ReleaseVersionTests {

    @Test("strips a leading v from a release tag", arguments: [
        ("v1.2.3", "1.2.3"),
        ("1.2.3", "1.2.3"),
        ("v0.1.0", "0.1.0"),
    ])
    func stripsTagPrefix(tag: String, expected: String) {
        #expect(ReleaseVersion.strip(tag) == expected)
    }

    /// The case that rules out a string compare. `"1.10.0" < "1.9.0"`
    /// lexicographically, and 1.9 → 1.10 is the first version bump this app
    /// will hit that a naive compare gets backwards.
    @Test("orders 1.10.0 above 1.9.0")
    func doubleDigitComponents() {
        #expect(ReleaseVersion.isNewer("1.10.0", than: "1.9.0"))
        #expect(!ReleaseVersion.isNewer("1.9.0", than: "1.10.0"))
    }

    @Test("recognises a newer version", arguments: [
        ("0.2.0", "0.1.0"),
        ("1.0.0", "0.9.9"),
        ("0.1.1", "0.1.0"),
        ("2.0.0", "1.99.99"),
    ])
    func newer(remote: String, local: String) {
        #expect(ReleaseVersion.isNewer(remote, than: local))
    }

    /// An equal version must not be "newer", or every check would offer the
    /// build the user is already running.
    @Test("an equal version is not newer", arguments: ["0.1.0", "1.10.3", "2.0.0"])
    func equalIsNotNewer(version: String) {
        #expect(!ReleaseVersion.isNewer(version, than: version))
    }

    @Test("an older version is not newer", arguments: [
        ("0.1.0", "0.2.0"),
        ("0.9.9", "1.0.0"),
        ("1.0.0", "1.0.1"),
    ])
    func olderIsNotNewer(remote: String, local: String) {
        #expect(!ReleaseVersion.isNewer(remote, than: local))
    }

    /// A missing component is zero, so 1.1 and 1.1.0 are the same version.
    /// Info.plist carries three components today, but a hand-typed tag of
    /// `v1.1` must not read as an upgrade over `1.1.0`.
    @Test("a missing component counts as zero", arguments: [
        ("1.1", "1.1.0"),
        ("1.1.0", "1.1"),
        ("1", "1.0.0"),
    ])
    func missingComponentsAreZero(remote: String, local: String) {
        #expect(!ReleaseVersion.isNewer(remote, than: local))
    }

    @Test("a longer version with a non-zero tail is newer")
    func longerTailIsNewer() {
        #expect(ReleaseVersion.isNewer("1.0.1", than: "1.0"))
        #expect(!ReleaseVersion.isNewer("1.0", than: "1.0.1"))
    }

    /// A tag that is not a version at all reads as 0, so it can never win
    /// against a real version. Anything else would let a stray tag like
    /// `latest` or `nightly` present itself as an upgrade.
    @Test("an unparseable remote version is never newer", arguments: [
        "latest", "nightly", "", "v", "abc.def",
    ])
    func garbageRemoteIsNeverNewer(remote: String) {
        #expect(!ReleaseVersion.isNewer(remote, than: "0.1.0"))
    }
}

@Suite("App release")
struct AppReleaseTests {

    /// The version is what gets compared, so it is stored already stripped
    /// rather than leaving every caller to remember to do it.
    @Test("carries the tag and its stripped version separately")
    func tagAndVersion() {
        let release = AppRelease(
            tag: "v0.2.0",
            assetURL: URL(string: "https://example.com/PRMaster.app.zip")!,
            sha256: "sha256:abc"
        )
        #expect(release.tag == "v0.2.0")
        #expect(release.version == "0.2.0")
    }
}
