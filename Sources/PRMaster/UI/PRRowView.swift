import SwiftUI
import PRMasterCore

struct PRRowView: View {
    let pr: PullRequest
    let canMerge: Bool
    /// True while the app is merging the base branch into this PR.
    let isUpdating: Bool
    /// Whether this pull request has been open longer than the user's threshold.
    /// Decided by the caller, which is the only place that knows the threshold.
    let isStale: Bool
    /// How old, in words. Passed in rather than computed here so the row reads
    /// one clock per redraw instead of one per row.
    let staleAge: String
    /// False while a debug override is active. Unlike `canMerge` there is no
    /// demo exception to this — see `CloseCoordinator`.
    let canClose: Bool
    let onOpen: () -> Void
    let onMerge: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        // Centred, not top-aligned: against a fixed two-line stack the glyph
        // reads as belonging to the row rather than to the title.
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: pr.readiness.symbolName)
                .foregroundStyle(palette.color(pr.readiness.tint))
                .font(.system(size: 14))
                .frame(width: 18)
                .accessibilityLabel(pr.readiness.label)

            VStack(alignment: .leading, spacing: 2) {
                // verbatim: PR titles are user content and must never be
                // parsed as a LocalizedStringKey format string.
                Text(verbatim: pr.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    // One line keeps every row the same height, so the list
                    // scans as a column rather than a ragged stack.
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Drafts stay visible but muted: present, not actionable.
                    // The dim lives on the title alone rather than on the whole
                    // row, which is where it used to be. Starting from full
                    // black or white the title still clears AA at 0.55 — 4.56:1
                    // light, 5.39:1 dark — whereas the grey status text below
                    // came out at 2.39:1, and no opacity short of 1 fixed that.
                    // The title is the dominant element, so the row still reads
                    // as muted either way.
                    .opacity(pr.readiness.isDimmed ? 0.55 : 1)

                HStack(spacing: 6) {
                    // verbatim again, otherwise Text applies locale grouping
                    // and PR #1204 renders as "#1.204".
                    Text(verbatim: "\(pr.repo) #\(pr.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        // Wins the squeeze against the status beside it, which
                        // only matters once a stale chip shares the line. The
                        // glyph at the leading edge already states the readiness
                        // twice over, in shape and in colour; nothing anywhere
                        // else on the row states which pull request this is.
                        .layoutPriority(1)
                    if isUpdating {
                        Text("Updating branch…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(pr.readiness.label)
                            // Semibold once colour is gone, so the status still
                            // separates from the grey "repo #1204" beside it.
                            .font(.system(
                                size: 11,
                                weight: palette.isMonochrome ? .semibold : .regular
                            ))
                            .foregroundStyle(palette.color(pr.readiness.tint))
                    }
                    // Trailing the line behind a Spacer, so the repo name and the
                    // status truncate before the age does. A row is 380pt wide and
                    // "acme/widget-service #1204 · Waiting for review" already
                    // fills most of it.
                    if isStale {
                        Spacer(minLength: 6)
                        staleChip
                    }
                }
                .lineLimit(1)
            }
            // The title truncates now, so the full text has to stay reachable.
            .help(pr.displayTitle)

            Spacer(minLength: 4)

            // Same rule as the merge button below: only offered where the action
            // applies. Plain against Merge's prominent style and to its left, so
            // that on a row which is both stale and ready the better outcome is
            // the one that looks like it.
            if isStale, isHovering, canClose {
                Button("Close", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            // Merging is irreversible, so the affordance only appears for PRs
            // that can actually be merged.
            if pr.readiness == .ready, isHovering, canMerge {
                Button("Merge", action: onMerge)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        // Text(verbatim:) for the same reason the row itself uses it: an
        // interpolated string literal is a LocalizedStringKey, which applies
        // locale grouping and had VoiceOver reading #1204 as "1.204".
        .accessibilityLabel(Text(verbatim: accessibilityDescription))
    }

    /// Orange rather than a new tint: `PaletteTests` proves a contrast floor
    /// across every `ReadinessTint`, and a seventh case would arrive unproven.
    /// Orange already means "this wants your attention" everywhere else in the
    /// popover, and the age sits in a different place from the readiness glyph,
    /// so sharing the colour with `conflicted` does not confuse the two.
    private var staleChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.badge.exclamationmark")
            // verbatim, or "31 days old" would be read as a format string.
            Text(verbatim: staleAge)
        }
        // Semibold once colour is gone, the same trick the status label uses:
        // in monochrome the words are all that is left to carry this.
        .font(.system(size: 11, weight: palette.isMonochrome ? .semibold : .regular))
        .foregroundStyle(palette.color(.orange))
    }

    /// The age has to be in here, or the one thing this feature adds to a row is
    /// invisible to VoiceOver — which is the only way some people read the list.
    ///
    /// Spelled out, unlike the chip: the chip is short because it shares a 380pt
    /// line with two other things and has a clock glyph to explain it, neither of
    /// which is true when the row is being read aloud.
    private var accessibilityDescription: String {
        let base = "\(pr.repo) pull request \(pr.number), "
            + "\(pr.displayTitle), \(pr.readiness.label)"
        return isStale ? base + ", opened \(staleAge) ago" : base
    }
}
