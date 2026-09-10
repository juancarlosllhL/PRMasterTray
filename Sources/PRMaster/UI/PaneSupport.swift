import SwiftUI
import PRMasterCore

/// The full-pane placeholder for an empty, loading or failed pane.
struct PaneMessageView: View {
    let icon: String
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .medium))
            if let detail {
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 11))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }
}

/// One banner row, orange for a complaint and blue for the update notice.
struct BannerRowView: View {
    let icon: String
    let text: String
    var isWarning = true
    var actionTitle: String?
    var action: (() -> Void)?
    var isBusy = false

    @Environment(\.palette) private var palette

    private var tint: ReadinessTint { isWarning ? .orange : .blue }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(palette.color(tint))
            Text(verbatim: text)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 0)
            if isBusy {
                ProgressView().controlSize(.small)
            } else if let actionTitle, let action {
                Button(actionTitle, action: action).font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.wash(tint))
    }
}

/// Section heading inside a pane.
struct PaneHeaderView: View {
    let title: String
    var trailing: String?
    var trailingHelp: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let trailing {
                Text(verbatim: trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(trailingHelp ?? "")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}
