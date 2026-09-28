import Foundation

public enum DiffLayout: String, Sendable, CaseIterable {
    case unified, split
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

    static func header(_ hunk: Hunk) -> String {
        let ranges = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        return hunk.context.isEmpty ? ranges : "\(ranges) \(hunk.context)"
    }
}
