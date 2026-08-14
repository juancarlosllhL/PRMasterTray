import SwiftUI
import PRMasterCore

struct ShipmentRowView: View {
    let shipment: Shipment
    let onOpen: () -> Void

    @State private var isHovering = false
    @Environment(\.palette) private var palette

    private var pr: MergedPullRequest { shipment.pr }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(palette.color(tint))
                .font(.system(size: 14))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                // verbatim: a pull request title is user content and must never
                // be parsed as a LocalizedStringKey format string.
                Text(verbatim: pr.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    // verbatim again, or #1204 renders as "1.204".
                    Text(verbatim: "\(pr.repo) #\(pr.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    // A version is whatever the release was tagged, and a check
                    // name is whatever CI called it. Neither is a format string.
                    Text(verbatim: statusLabel)
                        // Semibold once colour is gone, the same trick the open
                        // rows use: in monochrome the words carry this alone.
                        .font(.system(
                            size: 11,
                            weight: palette.isMonochrome ? .semibold : .regular
                        ))
                        .foregroundStyle(palette.color(tint))
                }
                .lineLimit(1)
            }
            .help(pr.displayTitle)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityDescription))
        .accessibilityAddTraits(.isButton)
    }

    /// Deliberately distinct from the readiness glyphs above: a shipped box is
    /// not the same statement as a mergeable checkmark, and a row that borrowed
    /// the glyph would read as one.
    private var symbolName: String {
        switch shipment.status {
        case .pending:  return "clock"
        case .building: return "arrow.triangle.2.circlepath"
        case .failed:   return "xmark.octagon.fill"
        case .released: return "shippingbox.fill"
        }
    }

    /// No new `ReadinessTint` case: `PaletteTests` proves a contrast floor
    /// across the existing six, and a seventh would arrive unproven.
    private var tint: ReadinessTint {
        switch shipment.status {
        case .pending:  return .gray
        case .building: return .gray
        case .failed:   return .red
        case .released: return .green
        }
    }

    private var statusLabel: String {
        switch shipment.status {
        case .pending:                return "Merged"
        case .building:               return "Building…"
        case .failed(let name, _):    return "\(name) failed"
        case .released(let version, _): return "Released \(version)"
        }
    }

    /// Says where the click goes, because the row gives no other clue and the
    /// destination differs by state.
    private var helpText: String {
        switch shipment.status {
        case .released: return "Open the release"
        case .pending:  return "Open the pull request"
        default:        return "Open the pipeline"
        }
    }

    private var accessibilityDescription: String {
        "\(pr.repo) pull request \(pr.number), \(pr.displayTitle), \(statusLabel)"
    }
}
