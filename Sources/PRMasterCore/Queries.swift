enum Queries {
    /// One query returns every signal the readiness rule needs, for a cost of
    /// a single rate-limit point against a 5000/hour budget.
    ///
    /// `mergeStateStatus` is the load-bearing field: `reviewDecision` alone is
    /// not enough, since a PR can report no required review while branch
    /// protection still blocks the merge.
    static let myOpenPullRequests = """
    query {
      search(
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
    }
    """

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
    /// has to be interpolated anywhere. Five is enough to cover a repository that
    /// cut several releases while a pipeline was running.
    static let releases = """
    query($repoIds: [ID!]!) {
      nodes(ids: $repoIds) {
        ... on Repository {
          id
          releases(first: 5, orderBy: {field: CREATED_AT, direction: DESC}) {
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
