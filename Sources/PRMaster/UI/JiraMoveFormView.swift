import SwiftUI
import PRMasterCore

/// Inline rather than a sheet: a sheet takes the popover's key window and closes it.
struct JiraMoveFormView: View {
    let request: JiraFieldRequest
    let onSubmit: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String] = [:]
    @State private var triedToSubmit = false
    @Environment(\.palette) private var palette

    private var problems: [String: String] { request.problems(in: values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(request.key) to \(request.to.name)")
                .font(.system(size: 12, weight: .semibold))
            Text(verbatim: "Jira asks for these before it leaves \(request.from.name).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach(request.fields) { field in
                row(field)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move") {
                    triedToSubmit = true
                    if problems.isEmpty { onSubmit(values) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(palette.wash(.blue).opacity(0.6))
    }

    private func binding(_ field: JiraField) -> Binding<String> {
        Binding { values[field.id] ?? "" } set: { values[field.id] = $0 }
    }

    @ViewBuilder
    private func row(_ field: JiraField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: field.name)
                .font(.system(size: 11, weight: .medium))
            input(field)
            if let prefix = field.addedPrefix {
                Text(verbatim: "PR Master adds \(prefix) if you leave it out.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if triedToSubmit, let problem = problems[field.id] {
                Text(verbatim: problem)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.orange))
            }
        }
    }

    @ViewBuilder
    private func input(_ field: JiraField) -> some View {
        switch field.kind {
        case .option(let allowed):
            Picker(field.name, selection: binding(field)) {
                Text("Choose…").tag("")
                ForEach(allowed, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        case .text:
            TextField(field.name, text: binding(field))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        case .richText:
            TextEditor(text: binding(field))
                .font(.system(size: 12))
                .frame(height: 54)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3))
                }
        }
    }
}
