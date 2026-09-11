import SwiftUI
import PRMasterCore

extension Font {
    static let rowTitle = Font.system(size: 12, weight: .medium)
}

extension View {
    func helpWhenTruncated(_ title: String, font: Font = .rowTitle) -> some View {
        modifier(TruncationHelp(title: title, font: font))
    }
}

private struct HidesEmojiKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hidesEmoji: Bool {
        get { self[HidesEmojiKey.self] }
        set { self[HidesEmojiKey.self] = newValue }
    }
}

/// A tooltip on every title turns a hover into noise, so the full text is
/// offered only where the row has run out of width to show it.
private struct TruncationHelp: ViewModifier {
    let title: String
    let font: Font

    @State private var shown: CGFloat = 0
    @State private var ideal: CGFloat = 0

    private var isTruncated: Bool {
        TitleOverflow.isTruncated(ideal: ideal, shown: shown)
    }

    func body(content: Content) -> some View {
        content
            .background { WidthReader { shown = $0 } }
            .background(alignment: .leading) { measuringCopy }
            .help(isTruncated ? title : "")
    }

    /// Laid out at its natural width and never drawn, which is the only way to
    /// learn what the visible copy would have needed.
    private var measuringCopy: some View {
        Text(verbatim: title)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .background { WidthReader { ideal = $0 } }
            .hidden()
            .accessibilityHidden(true)
    }
}

private struct WidthReader: View {
    let report: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { report(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in report(width) }
        }
    }
}
