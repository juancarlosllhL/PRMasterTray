import Foundation

/// One find hit: the table row, the column it is drawn in, and where in that line.
public struct DiffMatch: Equatable, Hashable, Sendable {
    public let row: Int
    public let column: Int
    public let range: Range<Int>

    public init(row: Int, column: Int, range: Range<Int>) {
        self.row = row
        self.column = column
        self.range = range
    }
}

/// Case-insensitive text search for the review window, in UTF-16 ranges so
/// the table can draw highlights straight onto its attributed strings.
public enum DiffSearch {

    public static func ranges(of query: String, in text: String) -> [Range<Int>] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let haystack = text as NSString
        var found: [Range<Int>] = []
        var start = 0
        while start < haystack.length {
            let match = haystack.range(
                of: query, options: .caseInsensitive, range: NSRange(location: start, length: haystack.length - start)
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            found.append(match.location..<(match.location + match.length))
            start = match.location + match.length
        }
        return found
    }

    public static func filter(_ files: [DiffFile], by query: String) -> [DiffFile] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return files }
        return files.filter { !ranges(of: query, in: $0.path).isEmpty }
    }

    /// Matches on the full path, split into the sidebar's two lines.
    public static func pathHighlights(of query: String, in path: String) -> (directory: [Range<Int>], name: [Range<Int>]) {
        let slash = (path as NSString).range(of: "/", options: .backwards)
        let directoryEnd = slash.location == NSNotFound ? 0 : slash.location
        let nameStart = slash.location == NSNotFound ? 0 : slash.location + 1
        var directory: [Range<Int>] = [], name: [Range<Int>] = []
        for match in ranges(of: query, in: path) {
            let inDirectory = match.clamped(to: 0..<directoryEnd)
            if !inDirectory.isEmpty { directory.append(inDirectory) }
            let inName = match.clamped(to: nameStart..<(path as NSString).length)
            if !inName.isEmpty { name.append((inName.lowerBound - nameStart)..<(inName.upperBound - nameStart)) }
        }
        return (directory, name)
    }

    public static func matches(of query: String, in rows: [DiffRow]) -> [DiffMatch] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var found: [DiffMatch] = []
        for (index, row) in rows.enumerated() {
            let sides: [DiffLine?]
            switch row {
            case .line(let line): sides = [line]
            case .pair(let left, let right): sides = [left, right]
            case .fileHeader, .section, .hunkHeader, .omitted: continue
            }
            for (column, line) in sides.enumerated() {
                guard let line else { continue }
                found += ranges(of: query, in: line.text).map { DiffMatch(row: index, column: column, range: $0) }
            }
        }
        return found
    }
}
