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
    let onTopFile: (String) -> Void

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
        // Views stopped clipping by default in macOS 14; the pinned header slides up out of the scroll view.
        scroll.clipsToBounds = true
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
        coordinator.onTopFile = onTopFile
        coordinator.update(rows: rows, layout: layout, palette: palette, metrics: metrics,
                           matches: matches, currentMatch: currentMatch)
        guard let target = scrollTarget else { return }
        coordinator.scroll(toFile: target)
        if let offset = Debug.scrollOffset {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { coordinator.scroll(by: offset) }
        }
        if let (from, to) = Debug.selectDrag {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { coordinator.selectForSnapshot(from: from, to: to) }
        }
        DispatchQueue.main.async { scrollTarget = nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        weak var pinned: PinnedHeaderView?
        var onToggleFile: ((String) -> Void)?
        var onTopFile: ((String) -> Void)?
        private var topFile: String?
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
        private(set) var textSelection: DiffTextSelection?

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
            let rowsChanged = rows != self.rows
            let wrapsChanged = layout != self.layout || metrics !== self.metrics
                || (rowsChanged && !DiffRows.wrapTheSame(rows, self.rows))
            let contentChanged = rowsChanged || wrapsChanged || palette != self.palette
            let currentMoved = currentMatch != self.currentMatch
            guard contentChanged || currentMoved || matches != self.matches else { return }
            if wrapsChanged { textSelection = nil }
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
                rewrap(table, force: wrapsChanged)
            }
            self.matches = matches
            matchesByRow = Dictionary(grouping: matches, by: \.row)
            self.currentMatch = currentMatch
            if contentChanged {
                table.reloadData()
            } else {
                refreshAvailableCells(table)
            }
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
            // Not noteHeightOfRows: it animates, and leaves the cells on screen
            // drawing their old wrapping inside the new heights.
            table.reloadData()
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
            reportTopFile(owning: topRow)
            table.window?.invalidateCursorRects(for: table)
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

        private func reportTopFile(owning row: Int) {
            guard row >= 0, let header = DiffRows.fileHeaderIndex(owning: row, in: rows),
                  case .fileHeader(let path) = rows[header], path != topFile
            else { return }
            topFile = path
            onTopFile?(path)
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
                case .section(let section, let count): segments = [wrap(section.heading(count: count), full)]
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
            case .fileHeader, .section, .hunkHeader, .omitted: return true
            case .line, .pair: return false
            }
        }

        /// Find only changes highlights, so the cells already built, including
        /// the ones prepared off screen, are redrawn in place rather than reloaded.
        private func refreshAvailableCells(_ table: NSTableView) {
            table.enumerateAvailableRowViews { rowView, row in
                for index in 0..<rowView.numberOfColumns {
                    guard let cell = rowView.view(atColumn: index) as? DiffCellView else { continue }
                    let column = rowView.isGroupRowStyle ? nil : table.tableColumns[safe: index]
                    configure(cell, row: row, tableColumn: column, in: table)
                }
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("DiffCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffCellView ?? {
                let view = DiffCellView()
                view.identifier = identifier
                return view
            }()
            configure(cell, row: row, tableColumn: tableColumn, in: tableView)
            return cell
        }

        private func configure(_ cell: DiffCellView, row: Int, tableColumn: NSTableColumn?, in tableView: NSTableView) {
            guard rows.indices.contains(row) else { return }
            let columnIndex = tableColumn.flatMap { tableView.tableColumns.firstIndex(of: $0) } ?? 0
            let segments = wraps.indices.contains(row)
                ? wraps[row].segments[min(columnIndex, wraps[row].segments.count - 1)]
                : [0..<0]
            let highlights = (matchesByRow[row] ?? [])
                .filter { $0.column == columnIndex }
                .map { (range: $0.range, isCurrent: $0 == currentMatch) }
            let selected = textSelection.flatMap { $0.column == columnIndex ? $0.range(inRow: row, in: rows) : nil }
            cell.configure(
                content(for: rows[row], column: tableColumn),
                palette: palette ?? .init(appearance: .light, contrast: .standard),
                segments: segments, metrics: metrics, highlights: highlights, selection: selected
            )
        }

        func setTextSelection(_ selection: DiffTextSelection?) {
            guard selection != textSelection, let table else { return }
            textSelection = selection
            refreshAvailableCells(table)
        }

        func selectForSnapshot(from: NSPoint, to: NSPoint) {
            guard let table else { return }
            let top = table.visibleRect.origin
            let start = NSPoint(x: top.x + from.x, y: top.y + from.y), end = NSPoint(x: top.x + to.x, y: top.y + to.y)
            guard let hit = textPosition(at: start) else { return NSLog("PRMASTER_SELECT: start is not in code") }
            var selection = self.selection(for: hit, clickCount: 1, extending: false)
            if let moved = textPosition(at: end, column: selection.column) { selection.focus = moved.position }
            setTextSelection(selection)
            NSLog("PRMASTER_SELECT copied: %@", selectedText() ?? "")
        }

        func selectedText() -> String? {
            textSelection.map { $0.text(in: rows) }
        }

        /// A new selection for a click: a word on a double-click, the line on a triple-click.
        func selection(
            for hit: (column: Int, position: DiffTextPosition), clickCount: Int, extending: Bool
        ) -> DiffTextSelection {
            let row = hit.position.row
            let text = DiffRows.text(of: rows[row], column: hit.column) ?? ""
            func span(_ range: Range<Int>) -> DiffTextSelection {
                DiffTextSelection(column: hit.column, anchor: DiffTextPosition(row: row, offset: range.lowerBound),
                                  focus: DiffTextPosition(row: row, offset: range.upperBound))
            }
            switch clickCount {
            case 2: return span(DiffTextSelection.word(at: hit.position.offset, in: text))
            case 3...: return span(0..<text.utf16.count)
            default:
                if extending, var current = textSelection, current.column == hit.column {
                    current.focus = hit.position
                    return current
                }
                return DiffTextSelection(column: hit.column, anchor: hit.position, focus: hit.position)
            }
        }

        /// Where a point falls in the code. Nil over a gutter, a header or no row, unless
        /// `column` is given for a drag, which clamps to the table instead.
        func textPosition(at point: NSPoint, column fixed: Int? = nil) -> (column: Int, position: DiffTextPosition)? {
            guard let table, !rows.isEmpty else { return nil }
            var row = table.row(at: point)
            if row < 0 {
                guard fixed != nil else { return nil }
                row = point.y < 0 ? 0 : rows.count - 1
            }
            let column = fixed ?? max(table.column(at: point), 0)
            guard let text = DiffRows.text(of: rows[row], column: column), wraps.indices.contains(row) else {
                return fixed == nil ? nil : (column, DiffTextPosition(row: row, offset: 0))
            }
            let cell = table.frameOfCell(atColumn: min(column, table.numberOfColumns - 1), row: row)
            let codeX = cell.minX + codeInset
            guard fixed != nil || point.x >= codeX else { return nil }
            let segments = wraps[row].segments[min(column, wraps[row].segments.count - 1)]
            let line = Int((point.y - cell.minY - DiffMetrics.verticalPadding) / metrics.lineHeight)
            let offset = LineWrap.offset(
                atColumn: Double((point.x - codeX) / metrics.advance), in: text,
                segment: segments[min(max(line, 0), segments.count - 1)],
                tabWidth: DiffMetrics.tabWidth, columns: metrics.columns
            )
            return (column, DiffTextPosition(row: row, offset: offset))
        }

        /// The code part of each visible line cell, for the I-beam.
        func codeRects(in visible: NSRect) -> [NSRect] {
            guard let table else { return [] }
            let range = table.rows(in: visible)
            return (range.location..<range.location + range.length).flatMap { row -> [NSRect] in
                guard rows.indices.contains(row) else { return [] }
                return (0..<table.numberOfColumns).compactMap { column in
                    guard DiffRows.text(of: rows[row], column: column) != nil else { return nil }
                    var rect = table.frameOfCell(atColumn: column, row: row)
                    rect.origin.x += codeInset
                    rect.size.width -= codeInset
                    return rect.intersection(visible)
                }
            }
        }

        private var codeInset: CGFloat {
            let gutter = layout == .split ? DiffMetrics.splitGutter : DiffMetrics.unifiedGutter
            return DiffMetrics.padding + CGFloat(gutter) * metrics.advance
        }

        private func content(for row: DiffRow, column: NSTableColumn?) -> DiffCellView.Content {
            switch row {
            case .fileHeader(let path): return .header(path, isFile: true)
            case .section(let section, let count): return .divider(section.heading(count: count))
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

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

final class CopyingTableView: NSTableView {
    weak var coordinator: DiffTableView.Coordinator?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        coordinator?.tableResized()
    }

    override func mouseDown(with event: NSEvent) {
        guard let coordinator, let hit = coordinator.textPosition(at: convert(event.locationInWindow, from: nil)) else {
            coordinator?.setTextSelection(nil)
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        deselectAll(nil)
        var selection = coordinator.selection(
            for: hit, clickCount: event.clickCount, extending: event.modifierFlags.contains(.shift)
        )
        coordinator.setTextSelection(selection)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            autoscroll(with: next)
            let point = convert(next.locationInWindow, from: nil)
            guard let moved = coordinator.textPosition(at: point, column: selection.column) else { continue }
            selection.focus = moved.position
            coordinator.setTextSelection(selection)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in coordinator?.codeRects(in: visibleRect) ?? [] { addCursorRect(rect, cursor: .iBeam) }
    }

    @objc func copy(_ sender: Any?) {
        let selected = coordinator?.selectedText().flatMap { $0.isEmpty ? nil : $0 }
        guard let text = selected ?? coordinator?.copyText(of: selectedRowIndexes), !text.isEmpty else { return }
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
    let italicFont: NSFont
    let boldItalicFont: NSFont
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
        italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        boldItalicFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
        advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = CGFloat(Self.tabWidth) * advance
        style.lineBreakMode = .byClipping
        paragraph = style
    }

    func font(for style: TokenStyle) -> NSFont? {
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): return boldItalicFont
        case (true, false): return boldFont
        case (false, true): return italicFont
        case (false, false): return nil
        }
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
        case divider(String)
        case notice(OmissionReason)
        case blank
    }

    private var content: Content = .blank
    private var segments: [Range<Int>] = [0..<0]
    private var highlights: [(range: Range<Int>, isCurrent: Bool)] = []
    private var selection: Range<Int>?
    private var metrics = DiffMetrics.forFont(family: nil, size: DiffFont.defaultSize, ligatures: true)
    private var palette = ResolvedPalette(appearance: .light, contrast: .standard)

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    func configure(
        _ content: Content, palette: ResolvedPalette, segments: [Range<Int>], metrics: DiffMetrics,
        highlights: [(range: Range<Int>, isCurrent: Bool)] = [], selection: Range<Int>? = nil
    ) {
        self.metrics = metrics
        self.highlights = highlights
        self.selection = selection
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
        if case .divider = content {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
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
        case .header, .divider, .notice: return .header
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
        case .divider(let text):
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: metrics.font.pointSize, weight: .semibold),
                .foregroundColor: isSelected && backgroundStyle == .emphasized ? colour : NSColor.secondaryLabelColor,
                .paragraphStyle: metrics.paragraph,
            ])
        case .notice(let reason):
            return NSAttributedString(string: Self.explanation(reason), attributes: base)
        case .line(let line, _):
            let text = NSMutableAttributedString(string: line.text, attributes: base)
            let start = 0
            if !(isSelected && backgroundStyle == .emphasized) {
                for token in line.tokens where token.location + token.length <= line.text.utf16.count {
                    let range = NSRange(location: start + token.location, length: token.length)
                    if !palette.isMonochrome {
                        let shown = Palette.syntax(token.colour, tint: tint, appearance: palette.appearance,
                                                   contrast: palette.contrast)
                        text.addAttribute(.foregroundColor, value: shown.nsColor, range: range)
                    }
                    if let font = metrics.font(for: token.style) { text.addAttribute(.font, value: font, range: range) }
                    if token.style.contains(.underline) {
                        text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
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
            if let selection, selection.upperBound <= text.length {
                text.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor,
                                  range: NSRange(location: selection.lowerBound, length: selection.count))
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
        case .header(let text, _), .divider(let text): return text
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
