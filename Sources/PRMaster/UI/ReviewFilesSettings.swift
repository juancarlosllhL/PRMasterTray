import SwiftUI
import PRMasterCore

struct ReviewFilesSettings: View {
    @Bindable var appearance: AppearanceStore
    @State private var section: FileSection = .tests

    var body: some View {
        Form {
            Section {
                Picker("List", selection: $section) {
                    ForEach(FileSection.secondary, id: \.self) { section in
                        Text(verbatim: section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextEditor(text: lines)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .frame(height: 170)
                HStack(alignment: .firstTextBaseline) {
                    if !invalidLines.isEmpty {
                        Text(verbatim: "Not understood: \(invalidLines.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Restore Defaults") { appearance.scopePatterns[section] = FileScope.defaultPatterns[section] }
                        .disabled(appearance.scopePatterns[section] == FileScope.defaultPatterns[section])
                }
            } footer: {
                Text("Files that match are set aside below the review, closed. One pattern per line, as in .gitignore: *.snap, fixtures/, /plans/, !keep/this.ts. A # line is a comment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Set aside files the repository marks linguist-generated", isOn: $appearance.honoursGitAttributes)
            } footer: {
                Text("Read from .gitattributes at the pull request's head, which its author can edit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var lines: Binding<String> {
        Binding(
            get: { (appearance.scopePatterns[section] ?? []).joined(separator: "\n") },
            set: { appearance.scopePatterns[section] = $0.components(separatedBy: "\n") }
        )
    }

    private var invalidLines: [String] {
        GlobList(lines: appearance.scopePatterns[section] ?? []).invalidLines
    }
}
