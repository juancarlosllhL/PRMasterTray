/// A status glyph the app draws itself, in one outline style, rather than an SF Symbol.
public enum StatusGlyph: String, Sendable, CaseIterable {
    case ready, behind, waiting, pending, failing, conflicted, draft
    case quill, comments, changesRequested, dismissed, approved
    case building, shipFailed, released, stale
}
