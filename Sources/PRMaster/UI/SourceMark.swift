import AppKit
import SwiftUI
import PRMasterCore

struct SourceMarks: View {
    let sources: [BoardCard.Source]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(sources, id: \.self) { SourceMark(source: $0) }
        }
    }
}

/// The Jira or GitHub mark at the head of a card. The marks are rendered into
/// the bundle by `make bundle`; a bare `swift run` has none and falls back to
/// SF Symbols.
struct SourceMark: View {
    let source: BoardCard.Source

    var body: some View {
        Group {
            if let image = NSImage(named: imageName) {
                Image(nsImage: image).renderingMode(.template).resizable()
            } else {
                Image(systemName: fallbackSymbol).resizable()
            }
        }
        .scaledToFit()
        .frame(width: 11, height: 11)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }

    private var imageName: String {
        switch source {
        case .jira:   return "jira-mark"
        case .github: return "github-mark"
        }
    }

    private var fallbackSymbol: String {
        switch source {
        case .jira:   return "square.stack.3d.up"
        case .github: return "arrow.triangle.pull"
        }
    }

    private var label: String {
        switch source {
        case .jira:                 return "From Jira"
        case .github(let project):  return project.isEmpty ? "From GitHub" : "From GitHub, \(project)"
        }
    }
}
