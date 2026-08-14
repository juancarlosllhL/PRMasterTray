enum Queries {
    /// Both halves of the list in one request: the open pull requests, and the
    /// ones merged inside the retention window.
    ///
    /// The open half's search string is a constant this app wrote. The merged
    /// half's carries a moving timestamp, so it rides as a variable rather than
    /// being pasted into the document on every poll.
    static let myPullRequests = """
    query($mergedQuery: String!) {
      open: search(
        query: "is:pr is:open author:@me archived:false sort:updated-desc"
        type: ISSUE
        first: 50
      ) {
        nodes {
          ... on PullRequest {
            id
            number
            title
            url
            isDraft
            headRefOid
            updatedAt
            createdAt
            mergeable
            mergeStateStatus
            reviewDecision
            repository { nameWithOwner isPrivate }
            commits(last: 1) {
              nodes { commit { statusCheckRollup { state } } }
            }
            reviews(states: APPROVED) { totalCount }
          }
        }
      }
      merged: search(query: $mergedQuery, type: ISSUE, first: 30) {
        nodes {
          ... on PullRequest {
            id
            number
            title
            url
            mergedAt
            repository { id nameWithOwner isPrivate }
            mergeCommit {
              oid
              statusCheckRollup {
                state
                contexts(first: 30) {
                  nodes {
                    __typename
                    ... on StatusContext { context state targetUrl }
                    ... on CheckRun { name status conclusion detailsUrl }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    /// The most recent releases of several repositories at once.
    ///
    /// Keyed by node ID rather than by owner and name: the merged search already
    /// returns `repository { id }`, so the IDs are in hand and no remote string
    /// has to be interpolated anywhere. How many to ask for is the window's
    /// call — see `MergedWindow.releaseDepth`, where it is a correctness matter
    /// rather than a tuning one.
    static let releases = """
    query($repoIds: [ID!]!, $first: Int!) {
      nodes(ids: $repoIds) {
        ... on Repository {
          id
          releases(first: $first, orderBy: {field: CREATED_AT, direction: DESC}) {
            nodes {
              tagName
              url
              createdAt
              isDraft
              tagCommit { oid }
            }
          }
        }
      }
    }
    """

    /// Asks, for each candidate, whether a release contains a merge commit.
    ///
    /// The only query in this app assembled from data GitHub sent us, which is
    /// why it is assembled the way it is: aliases and variable *names* are
    /// generated, and every remote *value* — owner, name, tag, oid — rides as a
    /// GraphQL variable. Nothing untrusted reaches the document text, so there
    /// is no escaping problem to get wrong.
    ///
    /// Aliases are generated because a tag name is not a legal GraphQL alias:
    /// `v3.31.2` ends at the first dot.
    ///
    /// - Returns: `nil` when there is nothing to ask, so the caller skips the
    ///   request rather than sending an empty document.
    static func containment(
        for candidates: [ContainmentCandidate]
    ) -> (query: String, variables: [String: String])? {
        guard !candidates.isEmpty else { return nil }

        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: String] = [:]

        for (index, candidate) in candidates.enumerated() {
            let owner = "owner\(index)"
            let name = "name\(index)"
            let tag = "tag\(index)"
            let oid = "oid\(index)"

            declarations.append("$\(owner): String!, $\(name): String!, $\(tag): String!, $\(oid): String!")
            fields.append("""
              t\(index): repository(owner: $\(owner), name: $\(name)) {
                ref(qualifiedName: $\(tag)) {
                  compare(headRef: $\(oid)) { status }
                }
              }
            """)

            let repo = candidate.pullRequest.repo
            variables[owner] = String(repo.prefix { $0 != "/" })
            variables[name] = String(repo.drop { $0 != "/" }.dropFirst())
            variables[tag] = "refs/tags/\(candidate.release.tagName)"
            variables[oid] = candidate.pullRequest.mergeCommitOid ?? ""
        }

        let query = """
        query(\(declarations.joined(separator: ", "))) {
        \(fields.joined(separator: "\n"))
        }
        """

        return (query, variables)
    }

    /// Lists each app folder in a deployments repository, with an oid per entry.
    ///
    /// Assembled from remote data on the same terms as `containment(for:)`:
    /// aliases and variable *names* are generated, and every remote value —
    /// owner, name, path — rides as a GraphQL variable.
    ///
    /// Addressed at `HEAD` rather than at `main`: nothing guarantees every
    /// deployments repository names its default branch the same way, and a
    /// wrong branch would read as an app nobody has ever promoted to.
    ///
    /// The entry oids are what make the blob reads skippable — see
    /// `promotionBlobs(for:)`.
    ///
    /// - Returns: `nil` when there is nothing to ask.
    static func promotionTrees(
        for locations: [AppLocation]
    ) -> (query: String, variables: [String: String])? {
        guard !locations.isEmpty else { return nil }

        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: String] = [:]

        for (index, location) in locations.enumerated() {
            declarations.append(
                "$owner\(index): String!, $name\(index): String!, $tree\(index): String!"
            )
            fields.append("""
              t\(index): repository(owner: $owner\(index), name: $name\(index)) {
                object(expression: $tree\(index)) {
                  ... on Tree { entries { name object { oid } } }
                }
              }
            """)

            let repo = location.deploymentsRepo
            variables["owner\(index)"] = String(repo.prefix { $0 != "/" })
            variables["name\(index)"] = String(repo.drop { $0 != "/" }.dropFirst())
            variables["tree\(index)"] = "HEAD:\(location.appPath)"
        }

        return (document(declarations, fields), variables)
    }

    /// Reads the text of specific values files.
    ///
    /// Only the blobs whose oid the caller has not already parsed need asking
    /// for, which is what keeps a steady-state poll to one tree listing.
    ///
    /// - Returns: `nil` when there is nothing to ask.
    static func promotionBlobs(
        for requests: [BlobRequest]
    ) -> (query: String, variables: [String: String])? {
        guard !requests.isEmpty else { return nil }

        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: String] = [:]

        for (index, request) in requests.enumerated() {
            declarations.append(
                "$owner\(index): String!, $name\(index): String!, $blob\(index): String!"
            )
            fields.append("""
              b\(index): repository(owner: $owner\(index), name: $name\(index)) {
                object(expression: $blob\(index)) {
                  ... on Blob { text }
                }
              }
            """)

            let repo = request.location.deploymentsRepo
            variables["owner\(index)"] = String(repo.prefix { $0 != "/" })
            variables["name\(index)"] = String(repo.drop { $0 != "/" }.dropFirst())
            variables["blob\(index)"] = "HEAD:\(request.location.appPath)/\(request.file)"
        }

        return (document(declarations, fields), variables)
    }

    private static func document(_ declarations: [String], _ fields: [String]) -> String {
        """
        query(\(declarations.joined(separator: ", "))) {
        \(fields.joined(separator: "\n"))
        }
        """
    }

    /// Merges the base branch into a PR that is behind it, refusing if the head
    /// has moved since the snapshot.
    ///
    /// `updateMethod` is deliberately absent, which selects GitHub's default of
    /// MERGE — the same thing its own "Update branch" button does. REBASE would
    /// force-push the user's branch and break every local clone of it, and the
    /// merge commit it avoids is squashed away at merge time anyway.
    static let updateBranch = """
    mutation($id: ID!, $oid: GitObjectID!) {
      updatePullRequestBranch(input: {
        pullRequestId: $id
        expectedHeadOid: $oid
      }) {
        pullRequest { id headRefOid }
      }
    }
    """

    /// Closes a pull request without merging it.
    ///
    /// No `expectedHeadOid`, and that is GitHub's doing rather than an omission:
    /// `ClosePullRequestInput` accepts only `pullRequestId` and
    /// `clientMutationId`. The merge and the branch update can both be made to
    /// refuse a pull request that moved since the snapshot; this cannot, so
    /// nothing here protects against acting on a stale row. `CloseCoordinator`'s
    /// debug gate is the whole of that protection, which is why it has no
    /// demo escape hatch the way the merge gate does.
    ///
    /// `state` is selected because it is the only trustworthy confirmation:
    /// GitHub documents no error text for closing a pull request that is already
    /// closed, already merged, or in an archived repository.
    static let closePullRequest = """
    mutation($id: ID!) {
      closePullRequest(input: { pullRequestId: $id }) {
        pullRequest { id state }
      }
    }
    """

    /// Squash-merges a PR, refusing if the head has moved since the snapshot.
    static let squashMerge = """
    mutation($id: ID!, $oid: GitObjectID!) {
      mergePullRequest(input: {
        pullRequestId: $id
        expectedHeadOid: $oid
        mergeMethod: SQUASH
      }) {
        pullRequest { merged }
      }
    }
    """
}
