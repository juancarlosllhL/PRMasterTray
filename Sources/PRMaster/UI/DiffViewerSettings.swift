import SwiftUI
import PRMasterCore

struct DiffViewerSettings: View {
    @Bindable var appearance: AppearanceStore
    @Bindable var heatmap: HeatmapAccountStore
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
                    .frame(height: 150)
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
            heatmapSection
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var heatmapSection: some View {
        Section {
            Toggle("Score changed lines by how closely to review them", isOn: $appearance.heatmapEnabled)
            if appearance.heatmapEnabled { heatmapAccount }
        } header: {
            HStack(spacing: 6) {
                Text("Review heatmap")
                Text("Experimental")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .accessibilityLabel("Experimental feature")
            }
        } footer: {
            Text(appearance.heatmapEnabled ? Self.heatmapOnNote : Self.heatmapOffNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let heatmapOffNote = "Adds a Score button to review windows that sends the changed lines to OpenRouter and colours each one by how closely to review it."
    private static let heatmapOnNote = "Press Score in a review window to send its changed lines to OpenRouter, where TypeSafe's Jev model scores them with data collection refused. Leave the API URL blank for OpenRouter, or give your proxy's base URL; the key is sent there too. The scores are hints from a model: nothing is hidden, and a pull request's own comments can sway them."

    @ViewBuilder
    private var heatmapAccount: some View {
            LabeledContent {
                SecureField("", text: $heatmap.token, prompt: Text(verbatim: heatmap.isConfigured ? "Saved" : "sk-or-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Text("OpenRouter key")
                    Link(destination: Self.keysURL) { Image(systemName: "arrow.up.forward.app") }
                        .help("Create a key at openrouter.ai")
                        .accessibilityLabel("Create an OpenRouter key")
                }
            }
            LabeledContent("API URL") {
                TextField("", text: $heatmap.apiURL, prompt: Text(verbatim: OpenRouterEndpoint.default.baseURL.absoluteString))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .autocorrectionDisabled()
            }
            if let problem = heatmap.urlProblem {
                LabeledContent("") { statusLine("exclamationmark.triangle.fill", problem) }
            }
            LabeledContent("") {
                HStack(spacing: 8) {
                    Button(heatmap.isConfigured ? "Test and Update" : "Test and Save") {
                        Task { await heatmap.testAndSave() }
                    }
                    .disabled(heatmap.state == .testing || heatmap.urlProblem != nil)
                    if heatmap.state == .testing { ProgressView().controlSize(.small) }
                    if heatmap.isConfigured { Button("Remove Key") { heatmap.signOut() } }
                    Spacer(minLength: 0)
                }
            }
            if let failure = heatmap.state.failureMessage {
                LabeledContent("") { statusLine("exclamationmark.triangle.fill", failure) }
            } else if heatmap.state == .succeeded {
                LabeledContent("") { statusLine("checkmark.circle.fill", "Key works. Press Score in a review window to use it.") }
            }
    }

    private static let keysURL = URL(string: "https://openrouter.ai/settings/keys")!

    private func statusLine(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(verbatim: text)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
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
