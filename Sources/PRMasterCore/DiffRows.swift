import Foundation

public enum DiffLayout: String, Sendable, CaseIterable {
    case unified, split

    public static let `default`: DiffLayout = .unified
}

/// One row of the diff table. The table draws these and nothing else.
public enum DiffRow: Sendable, Equatable {
    case fileHeader(path: String)
    case hunkHeader(String)
    case omitted(OmissionReason)
    case line(DiffLine)
    case pair(left: DiffLine?, right: DiffLine?)
}

public enum DiffRows {

    public static func build(_ files: [DiffFile], layout: DiffLayout, collapsed: Set<String>) -> [DiffRow] {
        var rows: [DiffRow] = []
        for file in files {
            rows.append(.fileHeader(path: file.path))
            guard !collapsed.contains(file.path) else { continue }
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

    public static func index(ofFile path: String, in rows: [DiffRow]) -> Int? {
        rows.firstIndex(of: .fileHeader(path: path))
    }

    public static func fileHeaderIndex(owning row: Int, in rows: [DiffRow]) -> Int? {
        guard rows.indices.contains(row) else { return nil }
        return rows[...row].lastIndex { if case .fileHeader = $0 { return true } else { return false } }
    }

    public static func nextFileHeaderIndex(after row: Int, in rows: [DiffRow]) -> Int? {
        guard row + 1 < rows.count else { return nil }
        return rows[(row + 1)...].firstIndex { if case .fileHeader = $0 { return true } else { return false } }
    }

    /// Unified lines keep their marker so the copy still reads as a diff; a
    /// split row copies its new side, or its old side where the new is blank.
    public static func copyText(_ rows: [DiffRow]) -> String {
        rows.compactMap { row -> String? in
            switch row {
            case .fileHeader(let path): return path
            case .hunkHeader(let header): return header
            case .omitted: return nil
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
