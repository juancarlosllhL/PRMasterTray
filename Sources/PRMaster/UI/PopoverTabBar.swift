import SwiftUI
import PRMasterCore

/// Hand-rolled rather than a segmented `Picker`, which on macOS cannot draw
/// anything but text per segment and so cannot carry a count.
struct PopoverTabBar: View {
    let tabs: [PopoverTab]
    @Binding var selection: PopoverTab
    let badges: [PopoverTab: TabBadge]

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                segment(tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func segment(_ tab: PopoverTab) -> some View {
        let isSelected = tab == selection
        let badge = badges[tab] ?? .none

        return Button {
            selection = tab
        } label: {
            HStack(spacing: 4) {
                Text(tab.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                badgeView(badge, isSelected: isSelected)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(selectionBackground(isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(tab, badge: badge))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func badgeView(_ badge: TabBadge, isSelected: Bool) -> some View {
        switch badge {
        case .none:
            EmptyView()
        case .count(let value):
            Text(verbatim: "\(value)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(palette.color(.orange))
        }
    }

    /// A selected segment is also drawn heavier above, so the fill is not the
    /// only thing distinguishing it under monochrome.
    private func selectionBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(isSelected ? Color.primary.opacity(0.10) : .clear)
    }

    /// The badge is spoken rather than left as decoration VoiceOver skips.
    private func accessibilityLabel(_ tab: PopoverTab, badge: TabBadge) -> String {
        switch badge {
        case .none:              return tab.label
        case .count(let value):  return "\(tab.label), \(value)"
        case .warning:           return "\(tab.label), needs attention"
        }
    }
}
