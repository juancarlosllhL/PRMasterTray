import Foundation

/// Talks to GitHub's GraphQL API.
///
/// An actor because the cached token is mutable state shared across the poll
/// loop, the popover's manual refresh and the notification's merge action.
public actor GitHubClient {

    private static let endpoint = URL(string: "https://api.github.com/graphql")!

    private let tokenProvider: TokenProvider
    private let session: URLSession
    private var cachedToken: String?

    public init(tokenProvider: TokenProvider = TokenProvider(), session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    // MARK: - API

    /// Both halves of the list in one request.
    ///
    /// The merged half is decoded from the same body as the open one, so a poll
    /// still costs a single round trip and the two can never describe different
    /// moments.
    public func fetchMyPullRequests(
        mergedWindow: MergedWindow = .oneDay
    ) async throws -> PullRequestSnapshot {
        let data = try await perform(
            query: Queries.myPullRequests,
            variables: [
                "mergedQuery": .string(Self.mergedSearch(window: mergedWindow, now: Date()))
            ]
        )
        return PullRequestSnapshot(
            open: try PullRequestDecoder.decodeSearch(data),
            merged: try PullRequestDecoder.decodeMergedSearch(data)
        )
    }

    static func mergedSearch(window: MergedWindow, now: Date) -> String {
        "is:pr is:merged author:@me archived:false "
            + "\(window.mergedQualifier(now: now)) sort:updated-desc"
    }

    /// The most recent releases of each repository, keyed by node ID.
    ///
    /// Skips the request entirely when nothing merged, which is most of the day:
    /// a lookup about no repositories is a rate-limit point spent on nothing.
    public func fetchReleases(
        repoIDs: [String], depth: Int = 5
    ) async throws -> [String: [Release]] {
        guard !repoIDs.isEmpty, depth > 0 else { return [:] }
        let data = try await perform(
            query: Queries.releases,
            variables: ["repoIds": .ids(repoIDs), "first": .int(depth)]
        )
        return try PullRequestDecoder.decodeReleases(data)
    }

    /// Asks whether each candidate release contains its pull request's merge
    /// commit.
    ///
    /// A candidate GitHub declines to answer for is left out of the result
    /// rather than recorded as "not contained": the resolver treats a missing
    /// answer as unknown and waits, which is the difference between a slow
    /// answer and a wrong one.
    public func resolveContainment(
        _ candidates: [ContainmentCandidate]
    ) async throws -> [ContainmentKey: Bool] {
        guard let built = Queries.containment(for: candidates) else { return [:] }
        let data = try await perform(
            query: built.query,
            variables: built.variables.mapValues(GraphQLValue.string)
        )
        return try PullRequestDecoder.decodeContainment(data, candidates: candidates)
    }

    // MARK: - Deployments

    /// Promoted versions already read, keyed by the blob oid they came from.
    /// Unchanged content is the same version, so a steady-state poll costs one
    /// tree listing and no blob reads at all.
    private var promotedVersions: [String: String] = [:]
    /// Oids already looked at, including those whose file named no version, so a
    /// file without one is not re-read on every poll.
    private var parsedOids: Set<String> = []

    /// The app folders a service repository ships into.
    ///
    /// Joined on the image name, which is the one string that appears verbatim
    /// on both sides — see `AppDiscovery`. Returns an empty array rather than
    /// throwing when the repository has no CircleCI config or names no image:
    /// plenty of repositories deploy nothing, and that is not an error.
    public func discover(repo: String) async throws -> [AppLocation] {
        let data = try await perform(
            query: Queries.fileText,
            variables: [
                "owner": .string(Self.owner(of: repo)),
                "name": .string(Self.name(of: repo)),
                "expression": .string("HEAD:.circleci/config.yml"),
            ]
        )
        guard let config = try PullRequestDecoder.decodeFileText(data) else { return [] }

        var hits: [(repo: String, path: String)] = []
        for image in AppDiscovery.imageNames(inCircleCIConfig: config) {
            hits += try await searchCode(image: image, org: Self.owner(of: repo))
        }
        return AppDiscovery.locations(fromSearchPaths: hits)
    }

    /// Every region's promoted version, per app folder.
    ///
    /// Two round trips at most: the tree listing always, and a blob read only
    /// for content not already parsed.
    public func promotions(
        for locations: [AppLocation]
    ) async throws -> [AppLocation: [PromotedVersion]] {
        guard let tree = Queries.promotionTrees(for: locations) else { return [:] }
        let treeData = try await perform(
            query: tree.query, variables: tree.variables.mapValues(GraphQLValue.string)
        )
        let trees = try PullRequestDecoder.decodePromotionTrees(treeData, locations: locations)

        // Only the region-qualified files are promotions; the rest of the folder
        // is charts and templates.
        let wanted: [(location: AppLocation, file: PromotionFile, entry: TreeEntry)] =
            locations.flatMap { location in
                (trees[location] ?? []).compactMap { entry in
                    PromotionFile.parse(name: entry.name).map { (location, $0, entry) }
                }
            }

        try await readUnparsedBlobs(in: wanted)

        // Pruned to what is still in play, so a long-running app cannot grow the
        // cache without bound as versions move on.
        let live = Set(wanted.map(\.entry.oid))
        promotedVersions = promotedVersions.filter { live.contains($0.key) }
        parsedOids = parsedOids.intersection(live)

        return wanted.reduce(into: [:]) { result, item in
            guard let version = promotedVersions[item.entry.oid] else { return }
            result[item.location, default: []].append(
                PromotedVersion(file: item.file, version: version)
            )
        }
    }

    private func readUnparsedBlobs(
        in wanted: [(location: AppLocation, file: PromotionFile, entry: TreeEntry)]
    ) async throws {
        var requests: [BlobRequest] = []
        var queued: Set<String> = []
        for item in wanted where !parsedOids.contains(item.entry.oid) {
            guard queued.insert(item.entry.oid).inserted else { continue }
            requests.append(
                BlobRequest(location: item.location, file: item.entry.name, oid: item.entry.oid)
            )
        }

        guard let blobs = Queries.promotionBlobs(for: requests) else { return }
        let data = try await perform(
            query: blobs.query, variables: blobs.variables.mapValues(GraphQLValue.string)
        )
        let texts = try PullRequestDecoder.decodePromotionBlobs(data, requests: requests)

        for request in requests {
            guard let text = texts[request.oid] else { continue }
            parsedOids.insert(request.oid)
            if let version = PromotionFile.stableVersion(in: text) {
                promotedVersions[request.oid] = version
            }
        }
    }

    /// Where an image name appears in the org's values files.
    ///
    /// REST rather than GraphQL because GitHub exposes code search only there.
    private func searchCode(image: String, org: String) async throws -> [(repo: String, path: String)] {
        var components = URLComponents(string: "https://api.github.com/search/code")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\"\(image)\" org:\(org) filename:values.yaml"),
            URLQueryItem(name: "per_page", value: "50"),
        ]

        let data = try await get(components.url!)
        let payload: CodeSearchPayload
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            payload = try decoder.decode(CodeSearchPayload.self, from: data)
        } catch {
            throw PRMasterError.decoding(String(describing: error))
        }
        return payload.items.map { (repo: $0.repository.fullName, path: $0.path) }
    }

    /// Brings a pull request up to date by merging its base branch into it.
    ///
    /// `expectedHeadOid` is the same control it is on the merge: this runs
    /// unattended off the poll loop, so if the branch moved after the snapshot
    /// the decision was made from, GitHub refuses rather than the app quietly
    /// pushing a commit onto work it has not seen.
    ///
    /// - Throws: `.updateRejected` carrying GitHub's own message.
    public func updateBranch(id: String, expectedHeadOid: String) async throws {
        let data = try await perform(
            query: Queries.updateBranch,
            variables: ["id": .string(id), "oid": .string(expectedHeadOid)]
        )
        try PullRequestDecoder.decodeBranchUpdate(data)
    }

    /// Closes a pull request without merging it.
    ///
    /// There is no head-oid guard to pass: GitHub does not offer one on this
    /// mutation. That makes this the one write in the app that cannot be made to
    /// refuse a stale snapshot, so the decision to call it is guarded entirely on
    /// the way in — see `CloseCoordinator`.
    ///
    /// - Throws: `.closeRejected` carrying GitHub's own message, or the same when
    ///   GitHub answers without confirming the pull request is closed.
    public func closePullRequest(id: String) async throws {
        let data = try await perform(query: Queries.closePullRequest, variables: ["id": .string(id)])
        try PullRequestDecoder.decodeClose(data)
    }

    /// Squash-merges a pull request.
    ///
    /// `expectedHeadOid` is a safety control, not an optimisation: if a commit
    /// landed after the snapshot the user was looking at, GitHub refuses the
    /// merge instead of merging code they never saw.
    ///
    /// - Throws: `.mergeRejected` carrying GitHub's own message.
    public func squashMerge(id: String, expectedHeadOid: String) async throws {
        let data = try await perform(
            query: Queries.squashMerge,
            variables: ["id": .string(id), "oid": .string(expectedHeadOid)]
        )
        try PullRequestDecoder.decodeMerge(data)
    }

    // MARK: - Transport

    private func token() throws -> String {
        if let cachedToken { return cachedToken }
        let fresh = try tokenProvider.token()
        cachedToken = fresh
        return fresh
    }

    /// Sends a GraphQL operation, retrying once on 401.
    ///
    /// `gh` rotates tokens, so a 401 usually means the cached copy went stale
    /// rather than that access was revoked. One silent re-read is worth it;
    /// retrying in a loop would just hammer GitHub with a dead credential.
    func perform(query: String, variables: [String: GraphQLValue] = [:]) async throws -> Data {
        do {
            return try await send(query: query, variables: variables, token: try token())
        } catch PRMasterError.unauthorized {
            cachedToken = nil
            let refreshed = try tokenProvider.token()
            cachedToken = refreshed
            do {
                return try await send(query: query, variables: variables, token: refreshed)
            } catch PRMasterError.unauthorized {
                throw PRMasterError.unauthorized
            }
        }
    }

    static func owner(of repo: String) -> String { String(repo.prefix { $0 != "/" }) }
    static func name(of repo: String) -> String { String(repo.drop { $0 != "/" }.dropFirst()) }

    /// Sends a REST GET, retrying once on 401 on the same terms as `perform`.
    private func get(_ url: URL) async throws -> Data {
        do {
            return try await sendGET(url, token: try token())
        } catch PRMasterError.unauthorized {
            cachedToken = nil
            let refreshed = try tokenProvider.token()
            cachedToken = refreshed
            return try await sendGET(url, token: refreshed)
        }
    }

    private func sendGET(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PRMaster", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PRMasterError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { return data }

        switch http.statusCode {
        case 200:
            guard Self.looksLikeJSON(data) else { throw PRMasterError.notJSON }
            return data
        case 401:
            throw PRMasterError.unauthorized
        // Code search is rate-limited far more tightly than the rest of the API,
        // and reports the secondary limit as a 403 rather than a 429.
        case 403, 429:
            throw PRMasterError.rateLimited(until: Self.resetDate(from: http))
        default:
            throw PRMasterError.httpError(status: http.statusCode)
        }
    }

    private func send(query: String, variables: [String: GraphQLValue], token: String) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PRMaster", forHTTPHeaderField: "User-Agent")

        var payload: [String: Any] = ["query": query]
        if !variables.isEmpty { payload["variables"] = variables.mapValues(\.jsonObject) }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PRMasterError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { return data }

        switch http.statusCode {
        case 200:
            // GitHub reports application-level failures in the body with a 200,
            // so the decoder is the arbiter — but only over JSON. Handing it an
            // HTML page produced a screenful of NSCocoaErrorDomain where one
            // sentence belongs.
            guard Self.looksLikeJSON(data) else { throw PRMasterError.notJSON }
            return data
        case 401:
            throw PRMasterError.unauthorized
        case 429:
            throw PRMasterError.rateLimited(until: Self.resetDate(from: http))
        default:
            // Every other status used to fall through to the decoder, which
            // could only describe a 502's HTML error page as an unexpected "<".
            throw PRMasterError.httpError(status: http.statusCode)
        }
    }

    /// Whether the body is even worth handing to a JSON decoder.
    ///
    /// A GraphQL reply is always a JSON object, so anything that does not open
    /// with `{` came from something other than the API — GitHub's own edge
    /// error page, a corporate proxy, or a captive portal.
    private static func looksLikeJSON(_ data: Data) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        guard let first = data.first(where: { !whitespace.contains($0) }) else { return false }
        return first == UInt8(ascii: "{")
    }

    private static func resetDate(from response: HTTPURLResponse) -> Date {
        guard let header = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
              let epoch = TimeInterval(header) else {
            return Date().addingTimeInterval(60)
        }
        return Date(timeIntervalSince1970: epoch)
    }
}
