import Foundation

public enum TokenKind: Sendable, Equatable, CaseIterable {
    case keyword, string, comment, number
}

/// A coloured span in UTF-16 units, so it maps straight onto an `NSRange`.
public struct TokenRange: Sendable, Equatable {
    public let location: Int
    public let length: Int
    public let kind: TokenKind

    public init(location: Int, length: Int, kind: TokenKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}

public struct LanguageTable: Sendable, Equatable {
    let keywords: Set<String>
    let lineComment: String?
    let blockComment: BlockComment?
    let quotes: Set<UInt16>

    struct BlockComment: Sendable, Equatable {
        let open: [UInt16]
        let close: [UInt16]
    }

    init(keywords: String, lineComment: String?, block: (String, String)?, quotes: String) {
        self.keywords = Set(keywords.split(separator: " ").map(String.init))
        self.lineComment = lineComment
        self.blockComment = block.map { BlockComment(open: Array($0.0.utf16), close: Array($0.1.utf16)) }
        self.quotes = Set(quotes.utf16)
    }

    public static func forPath(_ path: String) -> LanguageTable? {
        let ext = (path as NSString).pathExtension.lowercased()
        return byExtension[ext]
    }

    private static let cStyle = ("/*", "*/")

    static let swift = LanguageTable(
        keywords: "actor as associatedtype async await break case catch class continue default defer deinit do else enum extension false fileprivate final for func guard if import in init inout internal is let nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while any",
        lineComment: "//", block: cStyle, quotes: "\""
    )
    static let go = LanguageTable(
        keywords: "break case chan const continue default defer else fallthrough false for func go goto if import interface iota map nil package range return select struct switch true type var",
        lineComment: "//", block: cStyle, quotes: "\"'`"
    )
    static let typeScript = LanguageTable(
        keywords: "abstract as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function if implements import in instanceof interface let new null of private protected public readonly return static super switch this throw true try type typeof undefined var void while yield",
        lineComment: "//", block: cStyle, quotes: "\"'`"
    )
    static let cSharp = LanguageTable(
        keywords: "abstract as async await base bool break case catch class const continue decimal default delegate do double else enum event explicit false finally for foreach get if implicit in int interface internal is lock namespace new null object operator out override params private protected public readonly record ref return sealed set static string struct switch this throw true try typeof using var virtual void while",
        lineComment: "//", block: cStyle, quotes: "\"'"
    )
    static let python = LanguageTable(
        keywords: "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield self",
        lineComment: "#", block: nil, quotes: "\"'"
    )
    static let json = LanguageTable(keywords: "true false null", lineComment: nil, block: nil, quotes: "\"")
    static let yaml = LanguageTable(keywords: "true false null yes no on off", lineComment: "#", block: nil, quotes: "\"'")
    static let shell = LanguageTable(
        keywords: "if then else elif fi for do done while until case esac function in return export local readonly select",
        lineComment: "#", block: nil, quotes: "\"'"
    )

    private static let byExtension: [String: LanguageTable] = [
        "swift": swift, "go": go,
        "ts": typeScript, "tsx": typeScript, "js": typeScript, "jsx": typeScript, "mjs": typeScript, "cjs": typeScript,
        "cs": cSharp, "py": python, "json": json, "yml": yaml, "yaml": yaml,
        "sh": shell, "bash": shell, "zsh": shell,
    ]
}

public enum Tokenizer {

    /// The file with every hunk line carrying its own ranges, so rows built
    /// from it need no lookup.
    public static func highlighted(_ file: DiffFile) -> DiffFile {
        guard case .hunks(let hunks) = file.content else { return file }
        let content = DiffContent.hunks(hunks.map { hunk in
            var lines = hunk.lines
            for (index, ranges) in highlight(hunk, path: file.path).enumerated() {
                lines[index].tokens = ranges
            }
            return Hunk(
                oldStart: hunk.oldStart, oldCount: hunk.oldCount, newStart: hunk.newStart,
                newCount: hunk.newCount, context: hunk.context, lines: lines
            )
        })
        return DiffFile(
            path: file.path, previousPath: file.previousPath, change: file.change,
            additions: file.additions, deletions: file.deletions, content: content, viewed: file.viewed
        )
    }

    /// One range list per hunk line. The old and new sides are lexed as the
    /// two files they are, so a comment opened on one side stays there.
    public static func highlight(_ hunk: Hunk, path: String) -> [[TokenRange]] {
        guard let table = LanguageTable.forPath(path) else {
            return Array(repeating: [], count: hunk.lines.count)
        }
        let oldIndices = hunk.lines.indices.filter { hunk.lines[$0].kind != .added }
        let newIndices = hunk.lines.indices.filter { hunk.lines[$0].kind != .removed }
        let oldRanges = highlight(oldIndices.map { hunk.lines[$0].text }, table: table)
        let newRanges = highlight(newIndices.map { hunk.lines[$0].text }, table: table)

        var result = Array(repeating: [TokenRange](), count: hunk.lines.count)
        for (position, index) in oldIndices.enumerated() where hunk.lines[index].kind == .removed {
            result[index] = oldRanges[position]
        }
        for (position, index) in newIndices.enumerated() {
            result[index] = newRanges[position]
        }
        return result
    }

    public static func highlight(_ lines: [String], table: LanguageTable) -> [[TokenRange]] {
        var inBlockComment = false
        return lines.map { line in
            var lexer = Lexer(units: Array(line.utf16), table: table, inBlockComment: inBlockComment)
            let ranges = lexer.run()
            inBlockComment = lexer.inBlockComment
            return ranges
        }
    }
}

private struct Lexer {
    let units: [UInt16]
    let table: LanguageTable
    var inBlockComment: Bool
    private var ranges: [TokenRange] = []
    private var index = 0

    init(units: [UInt16], table: LanguageTable, inBlockComment: Bool) {
        self.units = units
        self.table = table
        self.inBlockComment = inBlockComment
    }

    mutating func run() -> [TokenRange] {
        if inBlockComment, let block = table.blockComment {
            closeBlockComment(from: 0, block)
        }
        while index < units.count {
            if let block = table.blockComment, matches(block.open, at: index) {
                closeBlockComment(from: index, block, skipping: block.open.count)
            } else if startsLineComment(at: index) {
                emit(index, units.count, .comment)
            } else if table.quotes.contains(units[index]) {
                emit(index, endOfString(from: index), .string)
            } else if isDigit(units[index]) && !isIdentifier(before: index) {
                emit(index, scan(from: index) { isIdentifierUnit($0) || $0 == dot }, .number)
            } else if isIdentifierStart(units[index]) {
                let end = scan(from: index, while: isIdentifierUnit)
                let word = String(decoding: units[index..<end], as: UTF16.self)
                if table.keywords.contains(word) { emit(index, end, .keyword) } else { index = end }
            } else {
                index += 1
            }
        }
        return ranges
    }

    private mutating func closeBlockComment(from start: Int, _ block: LanguageTable.BlockComment, skipping: Int = 0) {
        var cursor = start + skipping
        while cursor < units.count {
            if matches(block.close, at: cursor) {
                inBlockComment = false
                emit(start, cursor + block.close.count, .comment)
                return
            }
            cursor += 1
        }
        inBlockComment = true
        emit(start, units.count, .comment)
    }

    private func startsLineComment(at position: Int) -> Bool {
        guard let marker = table.lineComment, matches(Array(marker.utf16), at: position) else { return false }
        guard marker == "#" else { return true }
        return position == 0 || [space, tab].contains(units[position - 1])
    }

    private func endOfString(from start: Int) -> Int {
        let quote = units[start]
        var cursor = start + 1
        while cursor < units.count {
            if units[cursor] == backslash { cursor += 2; continue }
            if units[cursor] == quote { return cursor + 1 }
            cursor += 1
        }
        return units.count
    }

    private func matches(_ pattern: [UInt16], at position: Int) -> Bool {
        position + pattern.count <= units.count && units[position..<position + pattern.count].elementsEqual(pattern)
    }

    private func scan(from start: Int, while keep: (UInt16) -> Bool) -> Int {
        var cursor = start
        while cursor < units.count, keep(units[cursor]) { cursor += 1 }
        return cursor
    }

    private func isIdentifier(before position: Int) -> Bool {
        position > 0 && isIdentifierUnit(units[position - 1])
    }

    private mutating func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
        let end = min(end, units.count)
        if end > start { ranges.append(TokenRange(location: start, length: end - start, kind: kind)) }
        index = end
    }
}

private let space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t"))
private let backslash = UInt16(UInt8(ascii: "\\")), dot = UInt16(UInt8(ascii: "."))

private func isDigit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }

private func isIdentifierStart(_ unit: UInt16) -> Bool {
    (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit > 127
}

private func isIdentifierUnit(_ unit: UInt16) -> Bool {
    isIdentifierStart(unit) || isDigit(unit)
}
