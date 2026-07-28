import Foundation
import Testing
@testable import PRMasterCore

/// This is the only control standing between a downloaded zip and the app
/// replacing itself with it, so it is tested against published vectors rather
/// than against its own output.
@Suite("Release integrity")
struct ReleaseIntegrityTests {

    /// NIST vectors, so a rewrite of the hashing cannot quietly agree with
    /// itself while being wrong.
    @Test("hashes match the published SHA-256 vectors", arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    ])
    func knownVectors(input: String, expected: String) {
        #expect(ReleaseIntegrity.sha256(of: Data(input.utf8)) == expected)
    }

    @Test("hashes are lowercase hex of a fixed width")
    func hexShape() {
        let digest = ReleaseIntegrity.sha256(of: Data("PRMaster".utf8))
        #expect(digest.count == 64)
        #expect(digest == digest.lowercased())
    }

    /// GitHub reports the digest `sha256:`-prefixed. Accepting the bare form too
    /// means a caller that has already stripped it is not silently rejected.
    @Test("accepts GitHub's prefixed form and the bare form")
    func acceptsBothForms() {
        let data = Data("PRMaster".utf8)
        let bare = ReleaseIntegrity.sha256(of: data)

        #expect(ReleaseIntegrity.verify(data, matches: bare))
        #expect(ReleaseIntegrity.verify(data, matches: "sha256:\(bare)"))
    }

    @Test("compares hex case-insensitively")
    func caseInsensitive() {
        let data = Data("PRMaster".utf8)
        let upper = ReleaseIntegrity.sha256(of: data).uppercased()

        #expect(ReleaseIntegrity.verify(data, matches: upper))
        #expect(ReleaseIntegrity.verify(data, matches: "SHA256:\(upper)"))
    }

    @Test("a single changed byte fails")
    func tamperFails() {
        let original = Data("PRMaster".utf8)
        let digest = ReleaseIntegrity.sha256(of: original)

        #expect(!ReleaseIntegrity.verify(Data("PRMastes".utf8), matches: digest))
        #expect(!ReleaseIntegrity.verify(Data("PRMaster ".utf8), matches: digest))
    }

    // MARK: failing closed

    /// The whole point. An absent digest must not read as "nothing to check
    /// against, carry on" — our own workflow always uploads one, so its absence
    /// means something is wrong and the install has to stop.
    @Test("a missing digest refuses rather than waving the data through")
    func nilDigestRefuses() {
        #expect(!ReleaseIntegrity.verify(Data("PRMaster".utf8), matches: nil))
    }

    @Test("an empty or prefix-only digest refuses", arguments: ["", "sha256:", "   "])
    func emptyDigestRefuses(expected: String) {
        #expect(!ReleaseIntegrity.verify(Data("PRMaster".utf8), matches: expected))
    }

    /// Empty data has a perfectly valid digest, so a zero-byte download must
    /// only pass when the digest genuinely says so — not by accident.
    @Test("empty data is verified on its own merits")
    func emptyDataStillChecked() {
        let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(ReleaseIntegrity.verify(Data(), matches: emptyDigest))
        #expect(!ReleaseIntegrity.verify(Data(), matches: "sha256:0000"))
    }
}
