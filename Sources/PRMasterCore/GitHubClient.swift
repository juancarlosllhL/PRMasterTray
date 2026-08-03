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

    public func fetchMyPullRequests() async throws -> [PullRequest] {
        let data = try await perform(query: Queries.myOpenPullRequests)
        return try PullRequestDecoder.decodeSearch(data)
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
            variables: ["id": id, "oid": expectedHeadOid]
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
        let data = try await perform(query: Queries.closePullRequest, variables: ["id": id])
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
            variables: ["id": id, "oid": expectedHeadOid]
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
    func perform(query: String, variables: [String: String] = [:]) async throws -> Data {
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

    private func send(query: String, variables: [String: String], token: String) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PRMaster", forHTTPHeaderField: "User-Agent")

        var payload: [String: Any] = ["query": query]
        if !variables.isEmpty { payload["variables"] = variables }
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
