import Foundation

/// Reads the latest published release of PRMaster itself, so the store can be
/// driven without a network stack.
public protocol ReleaseChecking: Sendable {
    func fetchLatestRelease() async throws -> AppRelease
}

/// Talks to GitHub's REST releases API.
///
/// Separate from `GitHubClient` rather than another method on it: that one is
/// GraphQL, carries the user's `gh` token and speaks about pull requests. This
/// one is REST, deliberately unauthenticated — it reads a public repo, and
/// sending a credential where none is needed only widens the blast radius.
///
/// An actor for consistency with `GitHubClient`, not because it holds state.
public actor ReleaseClient: ReleaseChecking {

    /// GitHub's wire format. Only the fields this app acts on are declared;
    /// `Decodable` ignores the rest of the payload, which is most of it.
    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            /// Absent on assets uploaded before GitHub began publishing
            /// digests. Kept optional so a release still decodes; refusing is
            /// the installer's job, where it can be reported to the user.
            let digest: String?
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case digest
                // Snake-case conversion would yield `browserDownloadUrl`, which
                // would not match a property spelled `...URL`. Spelled out so a
                // rename cannot silently stop matching.
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private let repo: String
    private let assetName: String
    private let session: URLSession

    public init(
        // The repo is PRMasterTray; everything else — the app, the bundle id,
        // the executable and the asset — is PRMaster. Only this string and the
        // README's install URL follow the repo, and they have to agree.
        repo: String = "juancarlosllhL/PRMasterTray",
        assetName: String = "PRMaster.app.zip",
        session: URLSession = .shared
    ) {
        self.repo = repo
        self.assetName = assetName
        self.session = session
    }

    /// - Throws: `.noReleaseYet` when the repo has never been released,
    ///   `.releaseAssetMissing` when the release carries no matching asset.
    public func fetchLatestRelease() async throws -> AppRelease {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PRMaster", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PRMasterError.network(error)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                break
            case 404:
                // The state this repo is in until the first tag is pushed.
                throw PRMasterError.noReleaseYet
            default:
                // Unlike the GraphQL endpoint, REST does not report application
                // failures in a 200 body, so a non-200 is the whole story. The
                // status code is included because a 403 here means the
                // unauthenticated rate limit and a 5xx means GitHub is down —
                // different problems, and the user can tell them apart.
                throw PRMasterError.releaseCheckFailed("GitHub returned \(http.statusCode)")
            }
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw PRMasterError.decoding("\(error)")
        }

        // By exact name, never by position: a real release also carries source
        // tarballs, and whatever else was attached to it.
        guard let asset = payload.assets.first(where: { $0.name == assetName }) else {
            throw PRMasterError.releaseAssetMissing
        }

        return AppRelease(
            tag: payload.tagName,
            assetURL: asset.browserDownloadURL,
            sha256: asset.digest
        )
    }
}
