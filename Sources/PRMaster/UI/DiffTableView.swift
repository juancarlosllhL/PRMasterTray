import AppKit
import CoreText
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
    let fontFamily: String?
    let fontSize: Int
    let ligatures: Bool
    let matches: [DiffMatch]
    let currentMatch: DiffMatch?
    @Binding var scrollTarget: String?
    let onToggleFile: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    private var metrics: DiffMetrics {
        .forFont(family: fontFamily, size: fontSize, ligatures: ligatures)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = CopyingTableView()
        table.headerView = nil
        table.rowHeight = metrics.lineHeight + DiffMetrics.verticalPadding * 2
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
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // The clip view, not the table: row heights change the table's frame,
        // and rewrapping on that would feed itself.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.tableResized),
            name: NSView.frameDidChangeNotification, object: scroll.contentView
        )
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.updatePinnedHeader),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
        let pinned = PinnedHeaderView()
        pinned.isHidden = true
        pinned.onClick = { [weak coordinator = context.coordinator] in coordinator?.pinnedHeaderClicked() }
        scroll.addSubview(pinned, positioned: .below, relativeTo: scroll.verticalScroller)
        context.coordinator.pinned = pinned
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggleFile = onToggleFile
        coordinator.update(rows: rows, layout: layout, palette: palette, metrics: metrics,
                           matches: matches, currentMatch: currentMatch)
        guard let target = scrollTarget else { return }
        coordinator.scroll(toFile: target)
        if let offset = Debug.scrollOffset { coordinator.scroll(by: offset) }
        DispatchQueue.main.async { scrollTarget = nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        weak var pinned: PinnedHeaderView?
        var onToggleFile: ((String) -> Void)?
        private(set) var rows: [DiffRow] = []
        private var layout: DiffLayout?
        private var palette: ResolvedPalette?
        private var metrics = DiffMetrics.forFont(family: nil, size: DiffFont.defaultSize, ligatures: true)
        private var wraps: [RowWrap] = []
        private var capacities: [Int] = []
        private var isRewrapping = false
        private var pendingFile: String?
        private var matches: [DiffMatch] = []
        private var matchesByRow: [Int: [DiffMatch]] = [:]
        private var currentMatch: DiffMatch?

        /// Each column's wrapped segments for one row, and the height they need.
        private struct RowWrap {
            let segments: [[Range<Int>]]
            let height: CGFloat
        }

        func update(
            rows: [DiffRow], layout: DiffLayout, palette: ResolvedPalette, metrics: DiffMetrics,
            matches: [DiffMatch], currentMatch: DiffMatch?
        ) {
            guard let table else { return }
            let contentChanged = rows != self.rows || layout != self.layout || palette != self.palette
                || metrics !== self.metrics
            let currentMoved = currentMatch != self.currentMatch
            guard contentChanged || currentMoved || matches != self.matches else { return }
            if contentChanged {
                self.metrics = metrics
                table.rowHeight = metrics.lineHeight + DiffMetrics.verticalPadding * 2
                if layout != self.layout {
                    rebuildColumns(table, layout)
                    table.sizeToFit()
                }
                self.rows = rows
                self.layout = layout
                self.palette = palette
                rewrap(table, force: true)
            }
            self.matches = matches
            matchesByRow = Dictionary(grouping: matches, by: \.row)
            self.currentMatch = currentMatch
            table.reloadData()
            if currentMoved, let currentMatch { reveal(currentMatch, in: table) }
            if let file = pendingFile {
                pendingFile = nil
                scroll(toFile: file)
            }
            updatePinnedHeader()
        }

        /// Rewraps only when a column's width in characters changed. A large diff
        /// waits for the end of a live resize rather than rewrapping on every frame.
        @objc func tableResized() {
            guard let table, !isRewrapping, !(table.inLiveResize && rows.count > 5000) else { return }
            let before = capacities
            let top = topVisibleRow(table)
            rewrap(table, force: false)
            guard capacities != before else { return }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            scroll(table, toRow: top)
            updatePinnedHeader()
        }

        /// Shows the header of the file under the top edge once its own header
        /// has scrolled past, and lets the next file's header push it away.
        @objc func updatePinnedHeader() {
            guard let table, let pinned, let scroll = table.enclosingScrollView else { return }
            let clip = scroll.contentView
            let top = clip.bounds.minY
            let topRow = table.row(at: NSPoint(x: 0, y: top))
            guard topRow >= 0, let header = DiffRows.fileHeaderIndex(owning: topRow, in: rows),
                  table.rect(ofRow: header).minY < top, wraps.indices.contains(header),
                  case .fileHeader(let path) = rows[header]
            else {
                pinned.isHidden = true
                return
            }
            let height = wraps[header].height
            let push = DiffRows.nextFileHeaderIndex(after: header, in: rows)
                .map { min(0, table.rect(ofRow: $0).minY - top - height) } ?? 0
            pinned.configure(
                path: path, segments: wraps[header].segments[0],
                palette: palette ?? .init(appearance: .light, contrast: .standard), metrics: metrics
            )
            let frame = NSRect(x: clip.bounds.minX, y: top + push, width: clip.bounds.width, height: height)
            pinned.frame = scroll.convert(frame, from: clip)
            pinned.isHidden = false
        }

        /// Centres the match, so neither the pinned header nor the find bar covers it.
        private func reveal(_ match: DiffMatch, in table: NSTableView) {
            guard match.row < table.numberOfRows, let clip = table.enclosingScrollView?.contentView else { return }
            let row = table.rect(ofRow: match.row)
            let highest = max(0, table.bounds.height - clip.bounds.height)
            let y = min(max(0, row.midY - clip.bounds.height / 2), highest)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        func pinnedHeaderClicked() {
            guard let path = pinned?.path else { return }
            pendingFile = path
            onToggleFile?(path)
        }

        /// Rewrapping changes every height above the fold, so the row at the top
        /// is put back where it was rather than letting the content slide.
        private func topVisibleRow(_ table: NSTableView) -> Int? {
            guard let clip = table.enclosingScrollView?.contentView else { return nil }
            let row = table.row(at: NSPoint(x: 0, y: clip.bounds.minY))
            return row >= 0 ? row : nil
        }

        private func scroll(_ table: NSTableView, toRow row: Int?) {
            guard let row, row < table.numberOfRows, let clip = table.enclosingScrollView?.contentView else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: table.rect(ofRow: row).minY))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        private func rewrap(_ table: NSTableView, force: Bool) {
            isRewrapping = true
            defer { isRewrapping = false }
            let width = table.enclosingScrollView?.contentView.bounds.width ?? table.bounds.width
            let gutter = layout == .split ? DiffMetrics.splitGutter : DiffMetrics.unifiedGutter
            let columnWidth = width / CGFloat(max(table.tableColumns.count, 1))
            let code = table.tableColumns.map { _ in metrics.capacity(columnWidth, gutter: gutter) }
            let full = metrics.capacity(width, gutter: 0)
            let capacities = code + [full]
            guard force || capacities != self.capacities else { return }
            self.capacities = capacities

            func wrap(_ text: String?, _ width: Int) -> [Range<Int>] {
                LineWrap.segments(text ?? "", width: width, tabWidth: DiffMetrics.tabWidth, columns: metrics.columns)
            }
            wraps = rows.map { row in
                let segments: [[Range<Int>]]
                switch row {
                case .fileHeader(let path): segments = [wrap(path, full)]
                case .hunkHeader(let text): segments = [wrap(text, full)]
                case .omitted(let reason): segments = [wrap(DiffCellView.explanation(reason), full)]
                case .line(let line): segments = [wrap(line.text, code.first ?? full)]
                case .pair(let left, let right):
                    segments = [wrap(left?.text, code.first ?? full), wrap(right?.text, code.last ?? full)]
                }
                let lines = segments.map(\.count).max() ?? 1
                return RowWrap(segments: segments, height: CGFloat(lines) * metrics.lineHeight + DiffMetrics.verticalPadding * 2)
            }
        }

        func scroll(toFile path: String) {
            guard let table else { return }
            scroll(table, toRow: DiffRows.index(ofFile: path, in: rows))
        }

        func scroll(by offset: CGFloat) {
            guard let clip = table?.enclosingScrollView?.contentView else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + offset))
            table?.enclosingScrollView?.reflectScrolledClipView(clip)
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
                column.minWidth = 120
                table.addTableColumn(column)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            wraps.indices.contains(row) ? wraps[row].height : tableView.rowHeight
        }

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
            let columnIndex = tableColumn.flatMap { tableView.tableColumns.firstIndex(of: $0) } ?? 0
            let segments = wraps.indices.contains(row)
                ? wraps[row].segments[min(columnIndex, wraps[row].segments.count - 1)]
                : [0..<0]
            let highlights = (matchesByRow[row] ?? [])
                .filter { $0.column == columnIndex }
                .map { (range: $0.range, isCurrent: $0 == currentMatch) }
            cell.configure(
                content(for: rows[row], column: tableColumn),
                palette: palette ?? .init(appearance: .light, contrast: .standard),
                segments: segments, metrics: metrics, highlights: highlights
            )
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

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        coordinator?.tableResized()
    }

    @objc func copy(_ sender: Any?) {
        guard let text = coordinator?.copyText(of: selectedRowIndexes), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Find highlights: dark text on yellow reads in both appearances, and the
/// current match is orange so it stands out from the rest.
enum SearchHighlight {
    static let match = NSColor.systemYellow
    static let current = NSColor.systemOrange
    static let text = NSColor.black

    static func text(_ string: String, _ ranges: [Range<Int>]) -> AttributedString {
        var attributed = AttributedString(string)
        for range in ranges {
            guard let bounds = Range(NSRange(location: range.lowerBound, length: range.count), in: string),
                  let span = Range(bounds, in: attributed) else { continue }
            attributed[span].backgroundColor = Color(nsColor: match)
            attributed[span].foregroundColor = Color(nsColor: text)
        }
        return attributed
    }
}

/// The current file's header, drawn above the rows while its own row is scrolled away.
final class PinnedHeaderView: NSView {
    var onClick: (() -> Void)?
    private(set) var path: String?
    private let cell = DiffCellView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        cell.autoresizingMask = [.width, .height]
        addSubview(cell)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    func configure(path: String, segments: [Range<Int>], palette: ResolvedPalette, metrics: DiffMetrics) {
        self.path = path
        cell.frame = bounds
        cell.configure(.header(path, isFile: true), palette: palette, segments: segments, metrics: metrics)
        setAccessibilityLabel(path)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        cell.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.shadowOpacity = 0.15
        layer?.shadowRadius = 2
        layer?.shadowOffset = NSSize(width: 0, height: -1)
    }
}

/// Everything about drawing that depends on the chosen font, one per family.
@MainActor
final class DiffMetrics {
    static let padding: CGFloat = 6
    static let verticalPadding: CGFloat = 2
    static let tabWidth = 4
    /// Old number, new number and the sign, in characters.
    static let unifiedGutter = 14
    static let splitGutter = 8

    private static var cache: [String: DiffMetrics] = [:]

    static func forFont(family: String?, size: Int, ligatures: Bool) -> DiffMetrics {
        let key = "\(family ?? "")|\(size)|\(ligatures)"
        if let known = cache[key] { return known }
        let metrics = DiffMetrics(family: family, size: CGFloat(DiffFont.clampedSize(size)), ligatures: ligatures)
        cache[key] = metrics
        return metrics
    }

    let font: NSFont
    let boldFont: NSFont
    let advance: CGFloat
    let lineHeight: CGFloat
    let paragraph: NSParagraphStyle
    let ligatures: Bool
    private var measuredColumns: [UInt32: Double] = [:]

    private init(family: String?, size: CGFloat, ligatures: Bool) {
        self.ligatures = ligatures
        font = Self.withLigatures(ligatures, family.flatMap { MonospaceFonts.font(family: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
        boldFont = Self.withLigatures(ligatures, family.flatMap { MonospaceFonts.font(family: $0, size: size, bold: true) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold))
        advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = CGFloat(Self.tabWidth) * advance
        style.lineBreakMode = .byClipping
        paragraph = style
    }

    /// Coding fonts such as JetBrains Mono build ligatures from contextual
    /// alternates, so turning them off takes both features, not just one.
    private static func withLigatures(_ on: Bool, _ font: NSFont) -> NSFont {
        guard !on else { return font }
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Fallback fonts draw non-ASCII at their own widths: gqlgen's Ogham
    /// separators, CJK and emoji all differ from the monospaced advance.
    func columns(_ scalar: Unicode.Scalar) -> Double {
        if scalar.isASCII { return 1 }
        if let known = measuredColumns[scalar.value] { return known }
        let width = (String(scalar) as NSString).size(withAttributes: [.font: font]).width / advance
        measuredColumns[scalar.value] = width
        return width
    }

    /// How many characters of code fit beside the gutter in a column this wide.
    func capacity(_ width: CGFloat, gutter: Int) -> Int {
        max(10, Int(((width - Self.padding * 2) / advance).rounded(.down)) - gutter)
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
    private var segments: [Range<Int>] = [0..<0]
    private var highlights: [(range: Range<Int>, isCurrent: Bool)] = []
    private var metrics = DiffMetrics.forFont(family: nil, size: DiffFont.defaultSize, ligatures: true)
    private var palette = ResolvedPalette(appearance: .light, contrast: .standard)

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    func configure(
        _ content: Content, palette: ResolvedPalette, segments: [Range<Int>], metrics: DiffMetrics,
        highlights: [(range: Range<Int>, isCurrent: Bool)] = []
    ) {
        self.metrics = metrics
        self.highlights = highlights
        self.content = content
        self.palette = palette
        self.segments = segments
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
        var origin = NSPoint(x: DiffMetrics.padding, y: DiffMetrics.verticalPadding)
        if case .line(let line, let side) = content {
            let gutterText = gutter(line, side)
            NSAttributedString(string: gutterText, attributes: [.font: metrics.font, .foregroundColor: textColour])
                .draw(at: origin)
            origin.x += CGFloat(gutterText.count) * metrics.advance
        }
        let text = attributedText(colour: textColour)
        for (index, segment) in segments.enumerated() where segment.upperBound <= text.length {
            let range = NSRange(location: segment.lowerBound, length: segment.count)
            text.attributedSubstring(from: range)
                .draw(at: NSPoint(x: origin.x, y: origin.y + CGFloat(index) * metrics.lineHeight))
        }
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
            .font: metrics.font, .foregroundColor: colour, .paragraphStyle: metrics.paragraph,
            .ligature: metrics.ligatures ? 1 : 0,
        ]
        switch content {
        case .blank:
            return NSAttributedString()
        case .header(let text, let isFile):
            var attributes = base
            if isFile { attributes[.font] = metrics.boldFont }
            return NSAttributedString(string: text, attributes: attributes)
        case .notice(let reason):
            return NSAttributedString(string: Self.explanation(reason), attributes: base)
        case .line(let line, _):
            let text = NSMutableAttributedString(string: line.text, attributes: base)
            let start = 0
            if !(isSelected && backgroundStyle == .emphasized) {
                for token in line.tokens where token.location + token.length <= line.text.utf16.count {
                    let range = NSRange(location: start + token.location, length: token.length)
                    if palette.isMonochrome {
                        if token.kind == .keyword { text.addAttribute(.font, value: metrics.boldFont, range: range) }
                    } else {
                        let tokenColour = Palette.token(token.kind, appearance: palette.appearance, contrast: palette.contrast)
                        text.addAttribute(.foregroundColor, value: tokenColour.nsColor, range: range)
                    }
                }
            }
            for highlight in highlights where highlight.range.upperBound <= text.length {
                let range = NSRange(location: highlight.range.lowerBound, length: highlight.range.count)
                text.addAttributes([
                    .backgroundColor: highlight.isCurrent ? SearchHighlight.current : SearchHighlight.match,
                    .foregroundColor: SearchHighlight.text,
                ], range: range)
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
