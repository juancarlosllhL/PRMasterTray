import Foundation

/// Every way PRMaster can fail, phrased so the UI can show something the user
/// can act on rather than a generic "something went wrong".
public enum PRMasterError: Error, LocalizedError {
    /// The `gh` binary was not found at any known location.
    case ghNotFound
    /// `gh` is installed but has no usable token. The payload is a diagnostic
    /// for logs — it carries the exit code and never the captured output,
    /// which would be the token itself.
    case notAuthenticated(detail: String)
    /// GitHub rejected the token — rotated, revoked or expired.
    case unauthorized
    case network(URLError)
    /// HTTP 200 carrying an `errors` array, typically SAML SSO enforcement.
    case graphQL([String])
    case rateLimited(until: Date)
    /// A status the app cannot use. Only the code is carried, as with the
    /// release check: a 403 and a 502 are different problems and the user can
    /// tell them apart.
    case httpError(status: Int)
    /// GitHub refused the merge; the payload is its own message, verbatim.
    case mergeRejected(String)
    /// GitHub refused to bring the branch up to date; its own message, verbatim.
    case updateRejected(String)
    /// The body was not JSON at all, so there is nothing to decode. In practice
    /// this is a proxy or a Wi-Fi sign-in page answering in HTML instead of
    /// api.github.com answering in JSON.
    case notJSON
    /// The body was JSON but not the shape the app expects. The payload is a
    /// diagnostic — a `DecodingError` dump, which the message never shows.
    case decoding(String)
    /// The repo has no published release. Not a fault: it is the state the repo
    /// is in before the first tag is ever pushed.
    case noReleaseYet
    /// A release exists but carries no asset under the expected name — usually a
    /// release whose build failed after the tag was created.
    case releaseAssetMissing
    /// The release check reached GitHub and got something unusable back. The
    /// payload names the status code.
    case releaseCheckFailed(String)
    /// The downloaded asset did not match the sha256 GitHub published for it.
    /// Kept as its own case rather than folded into `updateFailed`: this is the
    /// one failure that means the bytes were wrong, not that a step went wrong.
    case updateVerificationFailed
    /// A step of the install went wrong — the download, the unpacking, or the
    /// shape of what was unpacked. The payload says which.
    case updateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "GitHub CLI not found. Install it with: brew install gh"
        case .notAuthenticated:
            return "Not signed in to GitHub. Run: gh auth login"
        case .unauthorized:
            return "GitHub rejected the token. Run: gh auth login"
        case .network(let error):
            // The common failures deserve plain language rather than
            // "NSURLErrorDomain error -1009".
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection."
            case .timedOut:
                return "GitHub timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Can't reach github.com."
            default:
                return "Network error: \(error.localizedDescription)"
            }
        case .graphQL(let messages):
            return messages.first ?? "GitHub returned an error."
        case .rateLimited(let until):
            return "Rate limited until \(until.formatted(date: .omitted, time: .shortened))."
        case .httpError(let status) where status >= 500:
            return "GitHub is having trouble (HTTP \(status)). Try again in a moment."
        case .httpError(let status):
            return "GitHub answered with HTTP \(status)."
        case .mergeRejected(let message), .updateRejected(let message):
            return message
        case .notJSON:
            // The likely culprit rather than a shrug: on a managed network
            // something else answers for api.github.com, and the user is the
            // only one who can tell whether they are behind a proxy.
            return "GitHub's answer wasn't JSON. If you're on a VPN or company network, a proxy is probably answering instead."
        case .decoding:
            // The payload is a DecodingError dump. It named a JSON path and an
            // error domain, which told the user nothing and buried the one fact
            // that mattered: this is not something they can fix.
            return "GitHub's response wasn't in a shape this app understands."
        case .noReleaseYet:
            return "No release has been published yet."
        case .releaseAssetMissing:
            return "That release has no PRMaster.app.zip attached."
        case .releaseCheckFailed(let detail):
            return "Couldn't check for updates — \(detail)"
        case .updateVerificationFailed:
            // Deliberately blunt. This is the one message that means the
            // download was not what GitHub said it was.
            return "The update failed its integrity check and was not installed."
        case .updateFailed(let detail):
            return "Couldn't install the update — \(detail)"
        }
    }
}

extension PRMasterError: Equatable {
    public static func == (lhs: PRMasterError, rhs: PRMasterError) -> Bool {
        switch (lhs, rhs) {
        case (.ghNotFound, .ghNotFound),
             (.unauthorized, .unauthorized),
             (.notJSON, .notJSON),
             (.noReleaseYet, .noReleaseYet),
             (.releaseAssetMissing, .releaseAssetMissing),
             (.updateVerificationFailed, .updateVerificationFailed):
            return true
        case (.notAuthenticated(let l), .notAuthenticated(let r)):
            return l == r
        case (.network(let l), .network(let r)):
            return l.code == r.code
        case (.graphQL(let l), .graphQL(let r)):
            return l == r
        case (.rateLimited(let l), .rateLimited(let r)):
            return l == r
        case (.httpError(let l), .httpError(let r)):
            return l == r
        case (.mergeRejected(let l), .mergeRejected(let r)),
             (.updateRejected(let l), .updateRejected(let r)):
            return l == r
        case (.decoding(let l), .decoding(let r)),
             (.releaseCheckFailed(let l), .releaseCheckFailed(let r)),
             (.updateFailed(let l), .updateFailed(let r)):
            return l == r
        default:
            return false
        }
    }
}
