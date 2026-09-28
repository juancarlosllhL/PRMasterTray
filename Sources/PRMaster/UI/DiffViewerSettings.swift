import SwiftUI
import PRMasterCore

struct DiffViewerSettings: View {
    @Bindable var appearance: AppearanceStore
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $appearance.diffFontFamily) {
                    Text("System (SF Mono)").tag(String?.none)
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(verbatim: family).tag(String?.some(family))
                    }
                }
                Text(verbatim: "func greet(_ name: String) -> String { \"Hello, \\(name)\" }")
                    .font(previewFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Only monospaced fonts installed on this Mac are listed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { families = MonospaceFonts.installed() }
    }

    private var previewFont: Font {
        guard let family = DiffFont.resolve(stored: appearance.diffFontFamily, installed: families) else {
            return .system(size: 12, design: .monospaced)
        }
        return .custom(family, size: 12)
    }
}
