import Foundation

public enum DiffLayout: String, Sendable, CaseIterable {
    case unified, split

    public static let `default`: DiffLayout = .unified
}

/// One row of the diff table. The table draws these and nothing else.
public enum DiffRow: Sendable, Equatable {
    case fileHeader(path: String)
    /// The divider above a set-aside group of files.
    case section(FileSection, count: Int)
    case hunkHeader(String)
    case omitted(OmissionReason)
    case line(DiffLine)
    case pair(left: DiffLine?, right: DiffLine?)
}

/// A place on the scroll track worth jumping to.
public struct HeatMark: Equatable, Sendable {
    public let row: Int
    /// How far down the table, from 0 to below 1.
    public let fraction: Double
    public let level: Importance
}

public struct DiffFileGroup: Sendable, Equatable {
    public let section: FileSection
    public let files: [DiffFile]

    public init(section: FileSection, files: [DiffFile]) {
        self.section = section
        self.files = files
    }
}

public enum DiffRows {

    public static func build(_ files: [DiffFile], layout: DiffLayout, collapsed: Set<String>) -> [DiffRow] {
        build(groups: [DiffFileGroup(section: .review, files: files)], layout: layout, isCollapsed: collapsed.contains)
    }

    /// Review files first, then each set-aside group that has files, behind a divider.
    public static func build(groups: [DiffFileGroup], layout: DiffLayout, isCollapsed: (String) -> Bool) -> [DiffRow] {
        let order = [FileSection.review] + FileSection.secondary
        var rows: [DiffRow] = []
        for section in order {
            let files = groups.filter { $0.section == section }.flatMap(\.files)
            if section != .review, !files.isEmpty { rows.append(.section(section, count: files.count)) }
            rows += fileRows(files, layout: layout, isCollapsed: isCollapsed)
        }
        return rows
    }

    private static func fileRows(_ files: [DiffFile], layout: DiffLayout, isCollapsed: (String) -> Bool) -> [DiffRow] {
        var rows: [DiffRow] = []
        for file in files {
            rows.append(.fileHeader(path: file.path))
            guard !isCollapsed(file.path) else { continue }
            switch file.content {
            case .omitted(let reason):
                rows.append(.omitted(reason))
            case .hunks(let hunks):
                for hunk in hunks {
                    switch layout {
                    case .unified:
                        rows.append(.hunkHeader(header(hunk)))
                        rows += hunk.lines.map(DiffRow.line)
                    case .split:
                        rows += split(hunk)
                    }
                }
            }
        }
        return rows
    }

    /// Pairs the removed and added lines of each change block in order, as
    /// GitHub does. Context ends a block and sits on both sides.
    static func split(_ hunk: Hunk) -> [DiffRow] {
        var rows: [DiffRow] = [.hunkHeader(header(hunk))]
        var removed: [DiffLine] = [], added: [DiffLine] = []

        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(.pair(
                    left: index < removed.count ? removed[index] : nil,
                    right: index < added.count ? added[index] : nil
                ))
            }
            removed = []
            added = []
        }

        for line in hunk.lines {
            switch line.kind {
            case .context:
                flush()
                rows.append(.pair(left: line, right: line))
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added:
                added.append(line)
            }
        }
        flush()
        return rows
    }

    /// Wrapping depends on text alone, so colour arriving later does not change it.
    public static func wrapTheSame(_ first: [DiffRow], _ second: [DiffRow]) -> Bool {
        first.count == second.count && zip(first, second).allSatisfy { pair in
            switch pair {
            case (.line(let a), .line(let b)): return a.text == b.text
            case (.pair(let leftA, let rightA), .pair(let leftB, let rightB)):
                return leftA?.text == leftB?.text && rightA?.text == rightB?.text
            default: return pair.0 == pair.1
            }
        }
    }

    /// One mark per unbroken run of business logic or sensitive rows.
    public static func heatMarks(_ rows: [DiffRow]) -> [HeatMark] {
        var marks: [HeatMark] = []
        var runStart: Int?
        var runLevel = Importance.glue
        for (index, row) in rows.enumerated() {
            guard let level = importance(of: row), level >= .logic else {
                if let start = runStart {
                    marks.append(HeatMark(row: start, fraction: Double(start) / Double(rows.count), level: runLevel))
                }
                runStart = nil
                continue
            }
            if runStart == nil {
                runStart = index
                runLevel = level
            } else {
                runLevel = max(runLevel, level)
            }
        }
        if let start = runStart {
            marks.append(HeatMark(row: start, fraction: Double(start) / Double(rows.count), level: runLevel))
        }
        return marks
    }

    private static func importance(of row: DiffRow) -> Importance? {
        switch row {
        case .line(let line): return line.heat?.level
        case .pair(let left, let right): return [left?.heat?.level, right?.heat?.level].compactMap { $0 }.max()
        default: return nil
        }
    }

    public static func index(ofFile path: String, in rows: [DiffRow]) -> Int? {
        rows.firstIndex(of: .fileHeader(path: path))
    }

    /// Nil above the first file and on a divider, which belongs to no file.
    public static func fileHeaderIndex(owning row: Int, in rows: [DiffRow]) -> Int? {
        guard rows.indices.contains(row), let boundary = rows[...row].lastIndex(where: isBoundary),
              case .fileHeader = rows[boundary]
        else { return nil }
        return boundary
    }

    /// The next file header or divider: either pushes the pinned header away.
    public static func nextFileHeaderIndex(after row: Int, in rows: [DiffRow]) -> Int? {
        guard row + 1 < rows.count else { return nil }
        return rows[(row + 1)...].firstIndex(where: isBoundary)
    }

    private static func isBoundary(_ row: DiffRow) -> Bool {
        switch row {
        case .fileHeader, .section: return true
        default: return false
        }
    }

    /// Unified lines keep their marker so the copy still reads as a diff; a
    /// split row copies its new side, or its old side where the new is blank.
    public static func copyText(_ rows: [DiffRow]) -> String {
        rows.compactMap { row -> String? in
            switch row {
            case .fileHeader(let path): return path
            case .hunkHeader(let header): return header
            case .omitted, .section: return nil
            case .line(let line): return marker(line.kind) + line.text
            case .pair(let left, let right): return (right ?? left)?.text
            }
        }.joined(separator: "\n")
    }

    private static func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: return " "
        case .added: return "+"
        case .removed: return "-"
        }
    }

    static func header(_ hunk: Hunk) -> String {
        let ranges = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        return hunk.context.isEmpty ? ranges : "\(ranges) \(hunk.context)"
    }
}
