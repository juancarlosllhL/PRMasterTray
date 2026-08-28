/// Whether a pull request waiting on your team is worth approving right now.
///
/// Its own enum rather than a reuse of `Readiness`, which is the app's answer to
/// "can I merge my change": `.behind` and `.conflicted` are things the *author*
/// acts on, and every row in this section would come out as `.blocked` —
/// "Waiting for review" — which is true, and tells a reviewer nothing.
public enum ReviewState: Sendable, Equatable, CaseIterable {
    /// A colleague has already asked for changes.
    case changesRequested
    /// A required check failed or errored.
    case checksFailing
    /// Checks are still running.
    case checksPending
    /// Somebody has approved and the team's request is still open, so it needs
    /// one more.
    case approved
    /// Nobody has reviewed it yet.
    case awaiting

    /// Evaluates a request against the review decision and the checks.
    ///
    /// Order matters, and it is not the same order `Readiness` uses.
    /// `changesRequested` dominates because it is a person's decision about the
    /// content: approving over the top of one overrides a colleague, not a build,
    /// and that is the one outcome a reviewer would want to be warned about.
    /// The checks then outrank `approved` for the same reason `Readiness` puts
    /// them above merge state — a red pull request is not waiting for another
    /// approval, it is waiting for a fix.
    public static func evaluate(_ request: ReviewRequest) -> ReviewState {
        if request.reviewDecision == .changesRequested { return .changesRequested }

        switch request.checks {
        case .failure, .error:
            return .checksFailing
        case .pending, .expected:
            return .checksPending
        case .success, nil:
            // nil means the repository has no CI at all. Treating that as
            // pending would leave every pull request in a CI-less repository
            // looking permanently unreviewable.
            break
        }

        return request.reviewDecision == .approved ? .approved : .awaiting
    }
}

extension ReviewState {

    /// SF Symbol shown at the leading edge of each row.
    ///
    /// All five are distinct, which matters more here than elsewhere: in
    /// monochrome the colour is gone and the glyph is most of what is left.
    public var symbolName: String {
        switch self {
        case .changesRequested: return "exclamationmark.bubble"
        case .checksFailing:    return "xmark.circle.fill"
        case .checksPending:    return "clock"
        // Deliberately not `checkmark.circle.fill`, which means "you can merge
        // this" everywhere else in the popover. This says somebody else has
        // approved and your team is still being asked, which is a different
        // claim — the same call `ShipmentRowView` makes about its own glyphs.
        case .approved:         return "checkmark.seal"
        case .awaiting:         return "eye.circle"
        }
    }

    /// No new `ReadinessTint` case: `PaletteTests` proves a contrast floor across
    /// the existing six, and a seventh would arrive unproven.
    ///
    /// `awaiting` shares blue with `Readiness.blocked` because the two mean the
    /// same thing seen from opposite ends — somebody's review is outstanding.
    public var tint: ReadinessTint {
        switch self {
        case .changesRequested: return .orange
        case .checksFailing:    return .red
        case .checksPending:    return .yellow
        case .approved:         return .green
        case .awaiting:         return .blue
        }
    }

    /// Short phrase for the row. Doubles as part of the accessibility label, so
    /// it has to read sensibly on its own.
    public var label: String {
        switch self {
        case .changesRequested: return "Changes requested"
        case .checksFailing:    return "Checks failing"
        case .checksPending:    return "Checks running"
        case .approved:         return "Approved by someone else"
        case .awaiting:         return "Waiting for review"
        }
    }
}
