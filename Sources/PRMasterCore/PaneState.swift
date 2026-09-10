import Foundation

/// What a pane draws instead of, or alongside, its rows.
public enum PaneState: String, Sendable, Equatable, CaseIterable {
    case loading
    case empty
    case emptyByFilter
    case content
    case stale
    case failed

    public var showsRows: Bool {
        self == .content || self == .stale
    }

    /// Branch order is load-bearing and matches what `PRListView.content` did.
    /// Rows first, so a failed refresh never blanks a list already on screen;
    /// then the error, so a first-fetch failure cannot sit on "Loading…".
    public static func resolve(
        rowCount: Int,
        hiddenCount: Int,
        lastError: PRMasterError?,
        lastSuccessfulFetch: Date?
    ) -> PaneState {
        if rowCount > 0 {
            return lastError == nil ? .content : .stale
        }
        if lastError != nil {
            return .failed
        }
        guard lastSuccessfulFetch != nil else { return .loading }
        return hiddenCount > 0 ? .emptyByFilter : .empty
    }
}
