import CryptoKit
import Foundation

/// Checks a downloaded release asset against the digest GitHub published for it.
///
/// This is the only meaningful integrity control available here. The app is
/// ad-hoc signed, so `codesign --verify` on the extracted bundle proves it was
/// not corrupted in transit but says nothing about *who* built it — there is no
/// Team ID and no certificate chain to check. The digest, read from the API over
/// TLS, is what pins the bytes to the ones the release workflow uploaded.
public enum ReleaseIntegrity {

    /// Lowercase hex, matching the form GitHub publishes.
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Whether `data` is exactly what `expected` describes.
    ///
    /// Fails closed. A `nil` or empty digest returns `false` rather than
    /// skipping the check: our own workflow always uploads one, so its absence
    /// means something is wrong with the release rather than that there is
    /// nothing to verify.
    ///
    /// - Parameter expected: GitHub's `digest` field, `sha256:`-prefixed or bare.
    public static func verify(_ data: Data, matches expected: String?) -> Bool {
        guard let expected else { return false }

        let want = expected
            .lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { return false }

        return sha256(of: data) == want
    }
}
