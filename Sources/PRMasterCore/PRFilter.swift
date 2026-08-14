/// Which of the fetched pull requests the app is interested in.
///
/// Applied to a fetch *before* the notification and branch-update decisions, so
/// hiding something means the app stops acting on it as well as showing it. The
/// alternative — filtering only the list — would leave a hidden PR notifying at
/// 2am and having its branch updated on a timer, which is the opposite of what
/// somebody asking to hide it meant.
///
/// Organizations are stored as the set to *hide* rather than the set to show.
/// That is the load-bearing choice in here: with an allowlist, the first pull
/// request you open in a new organization would be invisible, and silently
/// hiding a PR is the one failure this app cannot afford. A blocklist can only
/// ever hide something the user named.
/// What the filter needs to know about anything it hides.
///
/// Both an open and a merged pull request answer these, which is what makes
/// hiding survive a merge: an organization the user chose not to see must not
/// reappear in the section below just because the pull request landed.
public protocol FilterableRepository {
    var isPrivate: Bool { get }
    var organization: String { get }
}

extension PullRequest: FilterableRepository {}
extension MergedPullRequest: FilterableRepository {}

public struct PRFilter: Sendable, Equatable {

    /// Organization (or account) names whose pull requests are hidden, matched
    /// against `PullRequest.organization`.
    public var hiddenOrganizations: Set<String>

    /// Whether pull requests from private repositories are shown. Defaults to
    /// true: it is what the app did before this setting existed, and an update
    /// that quietly emptied the list would look like a bug.
    public var showsPrivateRepositories: Bool

    /// The default is deliberately "hide nothing".
    public init(
        hiddenOrganizations: Set<String> = [],
        showsPrivateRepositories: Bool = true
    ) {
        self.hiddenOrganizations = hiddenOrganizations
        self.showsPrivateRepositories = showsPrivateRepositories
    }

    /// Whether anything is being hidden at all, so the UI can say so.
    public var isActive: Bool {
        !hiddenOrganizations.isEmpty || !showsPrivateRepositories
    }

    public func includes(_ item: some FilterableRepository) -> Bool {
        if item.isPrivate && !showsPrivateRepositories { return false }
        return !hiddenOrganizations.contains(item.organization)
    }

    public func apply<T: FilterableRepository>(to items: [T]) -> [T] {
        // Ordering is the fetch's, which is GitHub's `sort:updated-desc`.
        items.filter(includes)
    }

    /// Flips one organization, so the UI can bind a checkbox straight to it.
    public mutating func setOrganization(_ organization: String, shown: Bool) {
        if shown {
            hiddenOrganizations.remove(organization)
        } else {
            hiddenOrganizations.insert(organization)
        }
    }

    public func shows(organization: String) -> Bool {
        !hiddenOrganizations.contains(organization)
    }
}
