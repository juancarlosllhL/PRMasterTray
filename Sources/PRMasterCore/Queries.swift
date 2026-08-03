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
