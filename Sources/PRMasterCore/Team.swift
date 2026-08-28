/// A GitHub team the signed-in user belongs to.
///
/// Identified by `combinedSlug` rather than by a node ID, which is the one place
/// this model departs from the rest of the app. The slug is what
/// `team-review-requested:` takes, so it is both the identity and the query
/// input; carrying a node ID as well would mean two identifiers for one thing and
/// a decision about which one the settings blocklist is keyed on.
///
/// `Codable` because the list is persisted: a failed discovery falls back to the
/// last good list rather than emptying the section, the rule `promotions` and
/// `shipments` already follow.
public struct Team: Identifiable, Sendable, Equatable, Hashable, Codable {

    /// `Org/team-slug`, e.g. `Lansweeper/asset-cortex`. Doubles as the key the
    /// settings blocklist stores, so it must survive a round trip untouched.
    public let combinedSlug: String
    /// The organization's login, taken from the node that answered rather than
    /// split off the slug: the login is the authoritative spelling and the slug
    /// is only conventionally built from it.
    public let organization: String
    /// The human name, e.g. `Asset Cortex`. Shown in settings, never in a query —
    /// a rename would break a query built from it.
    public let name: String

    public var id: String { combinedSlug }

    public init(combinedSlug: String, organization: String, name: String) {
        self.combinedSlug = combinedSlug
        self.organization = organization
        self.name = name
    }
}
