import Foundation

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

    /// Every team the signed-in user belongs to, across every organization.
    ///
    /// Both roles are asked for, and that is a correctness matter rather than
    /// belt-and-braces. `role` on `Organization.teams` is *viewer*-relative, and
    /// GitHub's `TeamRole` has exactly two cases: a plain member is `MEMBER`, a
    /// team maintainer is `ADMIN`. So `role: MEMBER` alone silently drops every
    /// team the user maintains — with no error, and invisibly, because the
    /// remaining teams answer perfectly well. Measured against a real account:
    /// `MEMBER` returned nine teams and `ADMIN` returned none, which is exactly
    /// the shape in which this bug would have gone unnoticed until somebody was
    /// promoted. The decoder unions the two.
    ///
    /// Not filtered by `userLogins:` instead, which would answer the same
    /// question in one field: that takes the login as an argument, and the login
    /// is only knowable from a prior round trip.
    ///
    /// `combinedSlug` is selected because it is `Org/team-slug`, exactly the form
    /// `team-review-requested:` takes. `name` is for the settings list only — a
    /// query built from a display name would break on a rename.
    ///
    /// Requires the `read:org` scope. Without it GitHub answers 200 with an
    /// errors array, which `decodeTeams` refuses to read as "no teams".
    static let myTeams = """
    query {
      viewer {
        organizations(first: 50) {
          nodes {
            login
            member: teams(first: 100, role: MEMBER) { nodes { name combinedSlug } }
            admin: teams(first: 100, role: ADMIN) { nodes { name combinedSlug } }
          }
        }
      }
    }
    """

    /// How many rows to fetch per enabled team.
    ///
    /// Per team rather than overall, which is the point of searching each one
    /// separately: on the account this was built for a single shared cap would
    /// have let one team with 852 pending crowd out another with 8.
    static let reviewRequestPageSize = 20

    /// The open pull requests each of the user's teams has been asked to review.
    ///
    /// One aliased search per team in one document — the `promotionTrees(for:)`
    /// pattern. Repeating `team-review-requested:` in a single search would OR
    /// the teams together and cost one request instead of several fields, but it
    /// was measured and rejected: one search needs one cap, and the volume is not
    /// evenly spread. Searching each team separately also makes attribution free,
    /// since the alias says which team answered.
    ///
    /// A team the user has switched off is still asked, at `first: 0`. GitHub
    /// answers `issueCount` whatever the page size, so this is what lets the
    /// settings list show a real number beside a disabled team — the number that
    /// says what switching it on would cost — without fetching a single row of it.
    ///
    /// Assembled from remote data on the same terms as `containment(for:)`:
    /// generated aliases and generated variable *names* only, with every remote
    /// value riding as a variable. A team slug is remote data.
    ///
    /// - Returns: `nil` when there are no teams, or when the window is off. Unlike
    ///   the merged search, which rides along with the open pull requests and so
    ///   costs nothing extra, this is a round trip of its own — there is nothing
    ///   to be gained by sending one that cannot match.
    static func reviewRequests(
        for teams: [Team], filter: TeamFilter, window: ReviewWindow, now: Date
    ) -> (query: String, variables: [String: GraphQLValue])? {
        guard !teams.isEmpty, let created = window.createdQualifier(now: now) else { return nil }

        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: GraphQLValue] = [:]

        for (index, team) in teams.enumerated() {
            declarations.append("$q\(index): String!, $n\(index): Int!")
            fields.append("""
              s\(index): search(query: $q\(index), type: ISSUE, first: $n\(index)) {
                issueCount
                nodes { \(reviewRequestFields) }
              }
            """)

            // `-author:@me` is required rather than tidy: GitHub refuses to let
            // anybody approve their own pull request, so a row of the user's own
            // would offer an Approve button that cannot work — and it is already
            // listed in the section above. `-reviewed-by:@me` drops the ones they
            // have dealt with, which would otherwise sit here until somebody else
            // cleared the team's request.
            variables["q\(index)"] = .string(
                "is:pr is:open archived:false draft:false "
                    + "team-review-requested:\(team.combinedSlug) -author:@me -reviewed-by:@me "
                    + "\(created) sort:updated-desc"
            )
            variables["n\(index)"] = .int(filter.shows(team) ? reviewRequestPageSize : 0)
        }

        return (document(declarations, fields), variables)
    }

    /// What a review row is made of.
    ///
    /// `isDraft` is deliberately absent: `draft:false` in the search already
    /// settles it, and a field nothing reads is a field that goes stale.
    /// `author` is nullable — GitHub reassigns a deleted account's pull requests
    /// to nobody — which the decoder handles rather than the query.
    private static let reviewRequestFields = """
    ... on PullRequest {
                    id
                    number
                    title
                    url
                    headRefOid
                    createdAt
                    updatedAt
                    additions
                    deletions
                    changedFiles
                    reviewDecision
                    author { login }
                    repository { nameWithOwner isPrivate }
                    commits(last: 1) {
                      nodes { commit { statusCheckRollup { state } } }
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

    /// The text of one file at a repository's default branch.
    ///
    /// A constant document with every value bound, so nothing is assembled here
    /// at all. Used to read a service repository's CircleCI config, which names
    /// the image that joins it to its deployments folders.
    static let fileText = """
    query($owner: String!, $name: String!, $expression: String!) {
      repository(owner: $owner, name: $name) {
        object(expression: $expression) {
          ... on Blob { text }
        }
      }
    }
    """

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

    /// The release each promoted version names, asked for by tag.
    ///
    /// Assembled on the same terms as the two above: aliases and variable names
    /// are generated, every remote value rides as a variable.
    ///
    /// Both spellings of the tag are asked at once. A values file names `3.31.1`
    /// and the release is tagged `v3.31.1`, but nothing guarantees the prefix, and
    /// GitHub answers a tag that does not exist with `null` rather than with an
    /// error — so the pair costs one field, not one request.
    ///
    /// - Returns: `nil` when there is nothing to ask.
    static func releasesByTag(
        for requests: [ReleaseTagRequest]
    ) -> (query: String, variables: [String: String])? {
        guard !requests.isEmpty else { return nil }

        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: String] = [:]

        for (index, request) in requests.enumerated() {
            declarations.append(
                "$owner\(index): String!, $name\(index): String!, "
                    + "$prefixed\(index): String!, $bare\(index): String!"
            )
            fields.append("""
              r\(index): repository(owner: $owner\(index), name: $name\(index)) {
                prefixed: release(tagName: $prefixed\(index)) { \(releaseFields) }
                bare: release(tagName: $bare\(index)) { \(releaseFields) }
              }
            """)

            let repo = request.repo
            variables["owner\(index)"] = String(repo.prefix { $0 != "/" })
            variables["name\(index)"] = String(repo.drop { $0 != "/" }.dropFirst())
            variables["prefixed\(index)"] = "v\(request.version)"
            variables["bare\(index)"] = request.version
        }

        return (document(declarations, fields), variables)
    }

    /// The same selection `releases` makes, so both paths decode into `Release`
    /// through one payload type and a draft is excluded on both.
    private static let releaseFields = "tagName url createdAt isDraft tagCommit { oid }"

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

    /// Approves a pull request on somebody else's behalf of your team.
    ///
    /// `commitOID` is *not* the control `expectedHeadOid` is on the merge, and the
    /// difference matters: GitHub pins the review to the named commit rather than
    /// refusing one that has moved since the snapshot. So this records which
    /// commit was approved — honest, and worth sending — but it cannot refuse an
    /// approval of a pull request that changed while the popover was open.
    /// `ApproveCoordinator` is the whole of that protection.
    ///
    /// `body` carries the approval remark — see `ApprovalQuip`. Nullable, so the
    /// variable is omitted entirely when the setting is off.
    ///
    /// `state` is selected because it is the only trustworthy confirmation — the
    /// same reason `closePullRequest` selects it. GitHub answers a review it
    /// declined to record as an approval with a perfectly well-formed 200.
    static let approvePullRequest = """
    mutation($id: ID!, $oid: GitObjectID!, $body: String) {
      addPullRequestReview(input: {
        pullRequestId: $id
        commitOID: $oid
        event: APPROVE
        body: $body
      }) {
        pullRequestReview { state }
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
