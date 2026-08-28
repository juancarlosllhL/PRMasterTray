/// Which of the user's teams have their review requests listed.
///
/// Stores the teams to *hide* rather than the ones to show, and that is the
/// load-bearing choice in here — the same one `PRFilter` makes for organizations,
/// for a reason that applies more strongly to teams. With an allowlist, the first
/// request from a team somebody has just been added to would be invisible, and
/// they would have no way of knowing it was there to go looking for. A blocklist
/// can only ever hide something the user named themselves. Teams are handed to
/// you by other people, so being added to one has to show up by itself.
///
/// Keyed on `combinedSlug`, which is `Team.id` and the same string the search
/// qualifier takes, so there is one name for a team throughout.
public struct TeamFilter: Sendable, Equatable {

    /// Teams whose review requests are not listed, by `combinedSlug`.
    public var disabledTeams: Set<String>

    /// The default is deliberately "hide nothing".
    public init(disabledTeams: Set<String> = []) {
        self.disabledTeams = disabledTeams
    }

    /// Whether anything is being hidden at all, so the UI can say so.
    public var isActive: Bool {
        !disabledTeams.isEmpty
    }

    public func shows(_ team: Team) -> Bool {
        !disabledTeams.contains(team.combinedSlug)
    }

    /// The teams to actually search, in the order given.
    ///
    /// That order is the caller's, which is the sorted order `decodeTeams`
    /// produces: the settings list reads in it and the search assigns its aliases
    /// in it.
    ///
    /// A stored name whose team no longer exists — somebody left it, or it was
    /// deleted — simply applies to nothing. It is not pruned here, because this
    /// type never sees the full list of teams and a name dropped on a failed
    /// discovery would switch a team back on behind the user's back.
    public func enabled(from teams: [Team]) -> [Team] {
        teams.filter(shows)
    }

    /// Flips one team, so the UI can bind a checkbox straight to it.
    public mutating func set(_ team: Team, shown: Bool) {
        if shown {
            disabledTeams.remove(team.combinedSlug)
        } else {
            disabledTeams.insert(team.combinedSlug)
        }
    }
}
