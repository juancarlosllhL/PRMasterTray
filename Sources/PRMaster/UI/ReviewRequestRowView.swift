import SwiftUI
import PRMasterCore

struct ReviewRequestRowView: View {
    let request: ReviewRequest
    /// False while a debug override is active. No demo exception, unlike the
    /// merge — see `ApproveCoordinator`.
    let canApprove: Bool
    /// True while an approval is in flight for this row.
    let isApproving: Bool
    /// How long it has been open, in words. Passed in rather than computed here so
    /// the list reads one clock per redraw instead of one per row.
    let age: String
    let onOpen: () -> Void
    let onApprove: () -> Void

    @State private var isHovering = false
    @Environment(\.palette) private var palette
    @Environment(\.hidesEmoji) private var hidesEmoji

    private var title: String { hidesEmoji ? request.plainTitle : request.displayTitle }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: request.state.symbolName)
                .foregroundStyle(palette.color(request.state.tint))
                .font(.system(size: 14))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                // verbatim: a pull request title is user content and must never
                // be parsed as a LocalizedStringKey format string.
                Text(verbatim: title)
                    .font(.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .helpWhenTruncated(title)

                HStack(spacing: 6) {
                    // verbatim again, or #1204 renders as "1.204".
                    Text(verbatim: "\(request.repo) #\(request.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        // Wins the squeeze: nothing else on the row says which
                        // pull request this is, while the state is already stated
                        // by the glyph's shape and colour.
                        .layoutPriority(1)
                    Text(verbatim: request.state.label)
                        // Semibold once colour is gone, the same trick the open
                        // rows use: in monochrome the words carry this alone.
                        .font(.system(
                            size: 11,
                            weight: palette.isMonochrome ? .semibold : .regular
                        ))
                        .foregroundStyle(palette.color(request.state.tint))
                }
                .lineLimit(1)

                // A third line rather than crowding the second. `ShipmentRowView`
                // already establishes that a three-line row is fine here, and the
                // author is the one fact a reviewer wants that an author never
                // does — it does not belong squeezed against the repository name.
                Text(verbatim: attribution)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .helpWhenTruncated(attribution, font: .system(size: 11))
            }

            Spacer(minLength: 4)

            if isApproving {
                ProgressView().controlSize(.small)
            } else if isHovering, canApprove {
                // Only on hover, the same rule the Merge and Close buttons
                // follow: this posts a real review under the user's name, so it
                // is not something to leave sitting under a stray click.
                Button("Approve", action: onApprove)
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
        // verbatim for the same reason the row uses it: an interpolated string
        // literal is a LocalizedStringKey, which locale-groups #1204 into "1.204".
        .accessibilityLabel(Text(verbatim: accessibilityDescription))
    }

    /// Who opened it, which of your teams was asked, and how long ago.
    ///
    /// The team is named because with several switched on the section is a mix,
    /// and "why am I seeing this" is otherwise unanswerable from the row. When
    /// two of your teams were asked, only the first is shown — the full list is
    /// in the tooltip and the accessibility label, and a row is 380pt wide.
    private var attribution: String {
        let team = request.teams.first?.name ?? ""
        let extra = request.teams.count > 1 ? " +\(request.teams.count - 1)" : ""
        return "@\(request.author) · \(team)\(extra) · \(age)"
    }

    /// "opened today" rather than "opened today ago", which is what interpolating
    /// the chip's own wording would produce.
    private var spokenAge: String {
        age == "today" ? "today" : "\(age) ago"
    }

    /// Spelled out, unlike the row: the abbreviations and the middot are for the
    /// eye, and neither survives being read aloud. Every team is named here, since
    /// there is no width to run out of.
    private var accessibilityDescription: String {
        let teams = request.teams.map(\.name).joined(separator: " and ")
        return "\(request.repo) pull request \(request.number), "
            + "\(title), \(request.state.label), "
            + "opened by \(request.author) \(spokenAge), waiting on \(teams)"
    }
}
