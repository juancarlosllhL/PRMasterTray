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
                        .truncationMode(.middle)
                    // A version is whatever the release was tagged, and a check
                    // name is whatever CI called it. Neither is a format string.
                    Text(verbatim: statusLabel)
                        // Wins the squeeze against the repository name, which is
                        // the opposite of the call PRRowView makes and for the
                        // opposite reason: a version truncated to "Rele…" loses
                        // the one thing this row exists to tell you, while a
                        // repository name is still recognisable clipped.
                        .layoutPriority(1)
                        // Semibold once colour is gone, the same trick the open
                        // rows use: in monochrome the words carry this alone.
                        .font(.system(
                            size: 11,
                            weight: palette.isMonochrome ? .semibold : .regular
                        ))
                        .foregroundStyle(palette.color(tint))
                }
                .lineLimit(1)

                // A line of their own: sharing one with the repository name
                // made the answer this row exists for compete for width with
                // the least interesting thing on it.
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips) { chip in
                            // verbatim: the version comes from a values file.
                            Text(verbatim: chip.label)
                                .font(.system(
                                    size: 11,
                                    weight: palette.isMonochrome ? .semibold : .regular
                                ))
                                .foregroundStyle(palette.color(chip.tint))
                        }
                    }
                    .lineLimit(1)
                }
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

    private struct Chip: Identifiable {
        let id: DeployEnvironment
        let label: String
        let tint: ReadinessTint
    }

    /// Only the environments something is known about. An empty list means the
    /// row keeps its original two-line shape rather than reserving a blank line.
    private var chips: [Chip] {
        shipment.environments.compactMap { state in
            guard let label = chipLabel(for: state) else { return nil }
            return Chip(id: state.environment, label: label, tint: chipTint(for: state.status))
        }
    }

    /// `nil` renders nothing at all. An environment nobody can answer for is
    /// better left silent than shown as a chip that means "we do not know".
    private func chipLabel(for state: EnvironmentState) -> String? {
        switch state.status {
        case .unknown:
            return nil
        case .awaiting(let version), .carrying(let version):
            // The version shown is the lowest across the regions, so a trailing
            // "+" is what distinguishes "everywhere on this" from "at least
            // this, and further along elsewhere".
            let rollout = state.regionsAgree ? "" : "+"
            return "\(name(of: state.environment)) \(version)\(rollout)"
        }
    }

    private func name(of environment: DeployEnvironment) -> String {
        switch environment {
        case .staging:    return "stg"
        case .production: return "prod"
        }
    }

    /// Green only for a change proven to be there. Everything else is grey:
    /// "not yet" is not a fault, so red would be a lie about a healthy rollout.
    private func chipTint(for status: EnvironmentStatus) -> ReadinessTint {
        switch status {
        case .carrying: return .green
        case .awaiting, .unknown: return .gray
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
        let chips = shipment.environments.compactMap(spokenChip)
        return ([
            "\(pr.repo) pull request \(pr.number)", pr.displayTitle, statusLabel,
        ] + chips).joined(separator: ", ")
    }

    /// Spelled out rather than read as "stg": the abbreviations are for the eye,
    /// and "promoted to" is the honest verb — the version reached the
    /// deployments repository, which is not the same as the cluster running it.
    private func spokenChip(for state: EnvironmentState) -> String? {
        let environment = state.environment == .staging ? "staging" : "production"
        switch state.status {
        case .unknown:
            return nil
        case .carrying(let version):
            return "\(version) promoted to \(environment)\(rolloutNote(for: state))"
        case .awaiting(let version):
            return "\(environment) is on \(version), which does not carry this change"
        }
    }

    private func rolloutNote(for state: EnvironmentState) -> String {
        state.regionsAgree ? "" : ", rollout still in flight"
    }
}
