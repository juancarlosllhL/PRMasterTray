import AppKit
import SwiftUI
import PRMasterCore

struct WhatsNewView: View {
    let entries: [ChangelogEntry]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(entries) { entry in
                        release(entry)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Continue", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: entries.contains { picture($0.image) != nil } ? 560 : 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("What's new in PR Master")
                .font(.system(size: 15, weight: .semibold))
            if let version = entries.first?.version {
                Text(verbatim: subtitle(upTo: version))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// Missing is not a failure: a changelog naming a picture that did not make
    /// it into the bundle still has its lines worth showing.
    private func picture(_ name: String?) -> NSImage? {
        guard let name,
              let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: nil)
                  ?? Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "WhatsNew")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    private func subtitle(upTo version: String) -> String {
        entries.count == 1
            ? "Version \(version)"
            : "Versions \(entries.last?.version ?? version) to \(version)"
    }

    /// The version is only worth a heading once several of them are stacked up,
    /// which is what a user who skipped a release sees.
    private func release(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if entries.count > 1 {
                Text(verbatim: entry.version)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let shot = picture(entry.image) {
                Image(nsImage: shot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.12))
                    }
                    .accessibilityLabel("A picture of what changed")
            }
            ForEach(entry.lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").foregroundStyle(.secondary)
                    Text(verbatim: line)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
            }
        }
    }
}
