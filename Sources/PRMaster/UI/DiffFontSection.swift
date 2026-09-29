import SwiftUI
import PRMasterCore

/// The review window's font, shown in the Appearance tab.
struct DiffFontSection: View {
    @Bindable var appearance: AppearanceStore
    @State private var families: [String] = []

    var body: some View {
        Section {
            Picker("Font", selection: $appearance.diffFontFamily) {
                Text("System (SF Mono)").tag(String?.none)
                Divider()
                ForEach(families, id: \.self) { family in
                    Text(verbatim: family).tag(String?.some(family))
                }
            }
            Picker("Size", selection: $appearance.diffFontSize) {
                ForEach(Array(DiffFont.sizes), id: \.self) { size in
                    Text(verbatim: "\(size) pt").tag(size)
                }
            }
            Toggle("Ligatures", isOn: $appearance.diffLigatures)
            Text(verbatim: "func greet(_ name: String) -> String { \"Hello, \\(name)\" } // != <= =>")
                .font(previewFont)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        } header: {
            Text("Diff Viewer")
        } footer: {
            Text("Only monospaced fonts installed on this Mac are listed. Ligatures join characters such as -> into one symbol; turn them off to see exactly what is in the file.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { families = MonospaceFonts.installed() }
    }

    /// The very font the diff draws with, so what the preview shows is what the window shows.
    private var previewFont: Font {
        let family = DiffFont.resolve(stored: appearance.diffFontFamily, installed: families)
        let metrics = DiffMetrics.forFont(family: family, size: appearance.diffFontSize, ligatures: appearance.diffLigatures)
        return Font(metrics.font as CTFont)
    }
}
