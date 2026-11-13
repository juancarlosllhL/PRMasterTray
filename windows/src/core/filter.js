// Which of the fetched pull requests the app is interested in. Port of PRFilter.swift.
//
// Applied to a fetch *before* the notification and branch-update decisions, so
// hiding something means the app stops acting on it as well as showing it: a
// hidden PR must not notify at 2am or have its branch updated on a timer.
//
// Organizations are a blocklist, deliberately: with an allowlist the first PR
// opened in a new organization would be invisible, and silently hiding a PR is
// the one failure this app cannot afford. A blocklist only hides what the user named.
export class PullRequestFilter {
  constructor({ hiddenOrganizations = [], showPrivateRepositories = true } = {}) {
    this.hiddenOrganizations = new Set(hiddenOrganizations);
    this.showPrivateRepositories = showPrivateRepositories;
  }

  // The owner half of `owner/name`: an organization, or the user's own account.
  static organizationOf(repo) {
    return repo.slice(0, repo.indexOf("/"));
  }

  // Whether anything is being hidden at all, so the UI can say so.
  get isActive() {
    return this.hiddenOrganizations.size > 0 || !this.showPrivateRepositories;
  }

  shows(organization) {
    return !this.hiddenOrganizations.has(organization);
  }

  includes(item) {
    if (item.isPrivate && !this.showPrivateRepositories) return false;
    return this.shows(item.organization ?? PullRequestFilter.organizationOf(item.repo));
  }

  // Ordering is the fetch's, which is GitHub's `sort:updated-desc`.
  apply(items) {
    return items.filter((item) => this.includes(item));
  }
}
