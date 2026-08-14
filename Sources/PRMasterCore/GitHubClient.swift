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
    public func fetchMyPullRequests() async throws -> PullRequestSnapshot {
        let data = try await perform(
            query: Queries.myPullRequests,
            variables: ["mergedQuery": .string(Self.mergedSearch(now: Date()))]
        )
        return PullRequestSnapshot(
            open: try PullRequestDecoder.decodeSearch(data),
            merged: try PullRequestDecoder.decodeMergedSearch(data)
        )
    }

    static func mergedSearch(now: Date) -> String {
        "is:pr is:merged author:@me archived:false "
            + "\(ShipmentRetention.mergedQualifier(now: now)) sort:updated-desc"
    }

    /// The most recent releases of each repository, keyed by node ID.
    ///
    /// Skips the request entirely when nothing merged, which is most of the day:
    /// a lookup about no repositories is a rate-limit point spent on nothing.
    public func fetchReleases(repoIDs: [String]) async throws -> [String: [Release]] {
        guard !repoIDs.isEmpty else { return [:] }
        let data = try await perform(
            query: Queries.releases,
            variables: ["repoIds": .ids(repoIDs)]
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
