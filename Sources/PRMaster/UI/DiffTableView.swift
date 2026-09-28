import AppKit
import SwiftUI
import PRMasterCore

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// The diff body: one reused, self-drawing row per line, so a very large diff
/// costs only the rows on screen.
struct DiffTableView: NSViewRepresentable {
    let rows: [DiffRow]
    let layout: DiffLayout
    let palette: ResolvedPalette
    @Binding var scrollTarget: String?
    let onToggleFile: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = CopyingTableView()
        table.headerView = nil
        table.rowHeight = DiffMetrics.rowHeight
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.style = .plain
        table.allowsMultipleSelection = true
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.coordinator = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggleFile = onToggleFile
        coordinator.update(rows: rows, layout: layout, palette: palette)
        guard let target = scrollTarget else { return }
        coordinator.scroll(toFile: target)
        DispatchQueue.main.async { scrollTarget = nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        var onToggleFile: ((String) -> Void)?
        private(set) var rows: [DiffRow] = []
        private var layout: DiffLayout?
        private var palette: ResolvedPalette?

        func update(rows: [DiffRow], layout: DiffLayout, palette: ResolvedPalette) {
            guard let table, rows != self.rows || layout != self.layout || palette != self.palette else { return }
            if layout != self.layout { rebuildColumns(table, layout) }
            self.rows = rows
            self.layout = layout
            self.palette = palette
            sizeColumns(table)
            table.reloadData()
        }

        func scroll(toFile path: String) {
            guard let table, let row = DiffRows.index(ofFile: path, in: rows),
                  let clip = table.enclosingScrollView?.contentView else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: table.rect(ofRow: row).minY))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        @objc func clicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row), case .fileHeader(let path) = rows[row] else { return }
            onToggleFile?(path)
        }

        func copyText(of indexes: IndexSet) -> String {
            DiffRows.copyText(indexes.filter { $0 < rows.count }.map { rows[$0] })
        }

        private func rebuildColumns(_ table: NSTableView, _ layout: DiffLayout) {
            table.tableColumns.forEach(table.removeTableColumn)
            let names = layout == .split ? ["old", "new"] : ["unified"]
            for name in names {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
                column.resizingMask = .autoresizingMask
                table.addTableColumn(column)
            }
        }

        /// Columns never shrink below their longest line, so long lines scroll
        /// sideways instead of being cut off.
        private func sizeColumns(_ table: NSTableView) {
            let longest = rows.reduce(0) { max($0, DiffMetrics.columns(in: $1)) }
            let gutter = layout == .split ? DiffMetrics.splitGutter : DiffMetrics.unifiedGutter
            let width = CGFloat(gutter + longest) * DiffMetrics.advance + DiffMetrics.padding * 2
            for column in table.tableColumns {
                column.minWidth = width
                column.width = max(column.width, width)
            }
            table.sizeToFit()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            switch rows[row] {
            case .fileHeader, .hunkHeader, .omitted: return true
            case .line, .pair: return false
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("DiffCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffCellView ?? {
                let view = DiffCellView()
                view.identifier = identifier
                return view
            }()
            cell.configure(content(for: rows[row], column: tableColumn), palette: palette ?? .init(appearance: .light, contrast: .standard))
            return cell
        }

        private func content(for row: DiffRow, column: NSTableColumn?) -> DiffCellView.Content {
            switch row {
            case .fileHeader(let path): return .header(path, isFile: true)
            case .hunkHeader(let text): return .header(text, isFile: false)
            case .omitted(let reason): return .notice(reason)
            case .line(let line): return .line(line, side: .unified)
            case .pair(let left, let right):
                let isOld = column?.identifier.rawValue == "old"
                guard let line = isOld ? left : right else { return .blank }
                return .line(line, side: isOld ? .old : .new)
            }
        }
    }
}

final class CopyingTableView: NSTableView {
    weak var coordinator: DiffTableView.Coordinator?

    @objc func copy(_ sender: Any?) {
        guard let text = coordinator?.copyText(of: selectedRowIndexes), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
enum DiffMetrics {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
    static let rowHeight = ceil(font.ascender - font.descender + font.leading) + 4
    static let padding: CGFloat = 6
    static let tabWidth = 4
    /// Old number, new number and the sign, in characters.
    static let unifiedGutter = 14
    static let splitGutter = 8

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = CGFloat(tabWidth) * advance
        style.lineBreakMode = .byClipping
        return style
    }()

    static func columns(in row: DiffRow) -> Int {
        switch row {
        case .fileHeader, .hunkHeader, .omitted: return 0
        case .line(let line): return columns(line.text)
        case .pair(let left, let right): return max(left.map { columns($0.text) } ?? 0, right.map { columns($0.text) } ?? 0)
        }
    }

    private static func columns(_ text: String) -> Int {
        text.utf16.reduce(0) { $0 + ($1 == 9 ? tabWidth : 1) }
    }
}

/// Draws its own row rather than holding subviews, which keeps scrolling cheap.
final class DiffCellView: NSTableCellView {
    enum Side { case unified, old, new }

    enum Content {
        case line(DiffLine, side: Side)
        case header(String, isFile: Bool)
        case notice(OmissionReason)
        case blank
    }

    private var content: Content = .blank
    private var palette = ResolvedPalette(appearance: .light, contrast: .standard)

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    func configure(_ content: Content, palette: ResolvedPalette) {
        self.content = content
        self.palette = palette
        setAccessibilityLabel(spokenText)
        needsDisplay = true
    }

    private var isSelected: Bool { (superview as? NSTableRowView)?.isSelected ?? false }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = palette.appearance, contrast = palette.contrast
        if isSelected {
            (backgroundStyle == .emphasized
                ? NSColor.selectedContentBackgroundColor
                : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        } else {
            Palette.diffBackground(tint, appearance: appearance, contrast: contrast).nsColor.setFill()
        }
        bounds.fill()

        let textColour = isSelected && backgroundStyle == .emphasized
            ? NSColor.alternateSelectedControlTextColor
            : Palette.diffText(appearance: appearance, contrast: contrast).nsColor
        let origin = NSPoint(x: DiffMetrics.padding, y: 2)
        guard case .line(let line, let side) = content else {
            attributedText(colour: textColour).draw(at: origin)
            return
        }
        let gutterText = gutter(line, side)
        NSAttributedString(string: gutterText, attributes: [.font: DiffMetrics.font, .foregroundColor: textColour])
            .draw(at: origin)
        let codeOrigin = NSPoint(x: origin.x + CGFloat(gutterText.count) * DiffMetrics.advance, y: origin.y)
        attributedText(colour: textColour).draw(at: codeOrigin)
    }

    private var tint: DiffLineTint {
        switch content {
        case .line(let line, _):
            switch line.kind {
            case .context: return .context
            case .added: return .added
            case .removed: return .removed
            }
        case .header, .notice: return .header
        case .blank: return .context
        }
    }

    private func attributedText(colour: NSColor) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: DiffMetrics.font, .foregroundColor: colour, .paragraphStyle: DiffMetrics.paragraph,
        ]
        switch content {
        case .blank:
            return NSAttributedString()
        case .header(let text, let isFile):
            var attributes = base
            if isFile { attributes[.font] = DiffMetrics.boldFont }
            return NSAttributedString(string: text, attributes: attributes)
        case .notice(let reason):
            return NSAttributedString(string: Self.explanation(reason), attributes: base)
        case .line(let line, _):
            let text = NSMutableAttributedString(string: line.text, attributes: base)
            let start = 0
            guard !(isSelected && backgroundStyle == .emphasized) else { return text }
            for token in line.tokens where token.location + token.length <= line.text.utf16.count {
                let range = NSRange(location: start + token.location, length: token.length)
                if palette.isMonochrome {
                    if token.kind == .keyword { text.addAttribute(.font, value: DiffMetrics.boldFont, range: range) }
                } else {
                    let tokenColour = Palette.token(token.kind, appearance: palette.appearance, contrast: palette.contrast)
                    text.addAttribute(.foregroundColor, value: tokenColour.nsColor, range: range)
                }
            }
            return text
        }
    }

    private func gutter(_ line: DiffLine, _ side: Side) -> String {
        func number(_ value: Int?) -> String {
            let text = value.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, 5 - text.count)) + text
        }
        let sign: String
        switch line.kind {
        case .context: sign = "  "
        case .added: sign = "+ "
        case .removed: sign = "- "
        }
        switch side {
        case .unified: return number(line.oldNumber) + " " + number(line.newNumber) + " " + sign
        case .old: return number(line.oldNumber) + " " + sign
        case .new: return number(line.newNumber) + " " + sign
        }
    }

    private var spokenText: String {
        switch content {
        case .blank: return ""
        case .header(let text, _): return text
        case .notice(let reason): return Self.explanation(reason)
        case .line(let line, _):
            let kind: String
            switch line.kind {
            case .context: kind = "unchanged"
            case .added: kind = "added"
            case .removed: kind = "removed"
            }
            let number = (line.newNumber ?? line.oldNumber).map { "line \($0), " } ?? ""
            return "\(kind) \(number)\(line.text)"
        }
    }

    static func explanation(_ reason: OmissionReason) -> String {
        switch reason {
        case .tooLarge: return "GitHub left this file's changes out because they are too large to show."
        case .noTextChanges: return "No text changes to show. The file is binary, empty, renamed, or only changed its mode."
        case .unparseable: return "GitHub's patch for this file couldn't be read. Open it on GitHub instead."
        }
    }
}
