import Foundation

public enum JiraBoard {
    public static let listWidth: Double = 380
    public static let columnWidth: Double = 230
    public static let gutter: Double = 8
    public static let outerPadding: Double = 10
    public static let columnHeight: Double = 380

    /// A popover measured wider than its display is repositioned rather than
    /// shrunk, so this leaves room for its own shadow and arrow.
    public static let screenMargin: Double = 40

    public static func width(columns: Int, available: Double) -> Double {
        guard columns > 0 else { return listWidth }
        let wanted = Double(columns) * columnWidth
            + Double(columns - 1) * gutter
            + 2 * outerPadding
        return max(listWidth, min(wanted, available - screenMargin))
    }

    /// The popover is only ever wide for a board that is actually on screen, so
    /// the tab and the flag are decided here rather than in the view.
    public static func popoverWidth(
        isBoardTab: Bool,
        showsBoard: Bool,
        columns: Int,
        available: Double
    ) -> Double {
        guard isBoardTab, showsBoard else { return listWidth }
        return width(columns: columns, available: available)
    }

    public static func layoutSummary(_ layout: JiraLayout, columns: Int) -> String {
        guard layout == .board else {
            return "One section under another, in the width the popover has always had."
        }
        return "A column per group. The popover widens to fit \(columns) of them "
            + "while the Board tab is open, and narrows again when it is not."
    }

    /// Shorter than the row's wording: a card is a column wide, not a popover.
    public static func cardLinkSummary(_ state: IssueLinkState, count: Int) -> String {
        switch state {
        case .loading: return "Checking…"
        case .unknown: return "Couldn't check"
        case .none:    return "No PRs"
        case .linked:  return count == 1 ? "1 pull request" : "\(count) pull requests"
        }
    }
}
