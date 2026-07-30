import SwiftUI
import PRMasterCore

struct PRRowView: View {
    let pr: PullRequest
    let canMerge: Bool
    /// True while the app is merging the base branch into this PR.
    let isUpdating: Bool
    let onOpen: () -> Void
    let onMerge: () -> Void

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
                }
                .lineLimit(1)
            }
            // The title truncates now, so the full text has to stay reachable.
            .help(pr.displayTitle)

            Spacer(minLength: 4)

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
        .accessibilityLabel(Text(
            verbatim: "\(pr.repo) pull request \(pr.number), "
                + "\(pr.displayTitle), \(pr.readiness.label)"
        ))
    }
}
