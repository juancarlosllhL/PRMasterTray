import Foundation

public enum PatchError: Error, Equatable, Sendable {
    case malformedHeader(String)
    case unexpectedLine(String)
    case truncatedHunk
}

/// Reads the `patch` GitHub returns per file into numbered hunks.
///
/// Driven by the counts in each header, the way `git apply` reads a patch, so a
/// patch that disagrees with its own header is refused instead of misnumbered.
public enum PatchParser {

    public static func hunks(_ patch: String) throws -> [Hunk] {
        var lines = patch.components(separatedBy: "\n").map(stripCarriageReturn)
        if lines.last == "" { lines.removeLast() }

        var hunks: [Hunk] = []
        var index = 0
        while index < lines.count {
            let header = try Header(lines[index])
            index += 1
            var body: [DiffLine] = []
            var oldNumber = header.oldStart, newNumber = header.newStart
            var oldLeft = header.oldCount, newLeft = header.newCount

            while oldLeft > 0 || newLeft > 0 || lines[safe: index]?.unicodeScalars.first == "\\" {
                guard let line = lines[safe: index] else { throw PatchError.truncatedHunk }
                index += 1
                let scalars = line.unicodeScalars
                let text = String(String.UnicodeScalarView(scalars.dropFirst()))
                switch scalars.first {
                case "\\":
                    guard let last = body.popLast() else { throw PatchError.unexpectedLine(line) }
                    body.append(last.withNoNewlineAtEnd())
                case "-" where oldLeft > 0:
                    body.append(DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil, text: text))
                    oldNumber += 1; oldLeft -= 1
                case "+" where newLeft > 0:
                    body.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber, text: text))
                    newNumber += 1; newLeft -= 1
                case " " where oldLeft > 0 && newLeft > 0, nil where oldLeft > 0 && newLeft > 0:
                    body.append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: text))
                    oldNumber += 1; newNumber += 1; oldLeft -= 1; newLeft -= 1
                default:
                    throw PatchError.unexpectedLine(line)
                }
            }

            hunks.append(Hunk(
                oldStart: header.oldStart, oldCount: header.oldCount,
                newStart: header.newStart, newCount: header.newCount,
                context: header.context, lines: body
            ))
        }
        return hunks
    }

    /// Per scalar: Swift reads `\r\n` as a single character, not two.
    private static func stripCarriageReturn(_ line: String) -> String {
        guard line.unicodeScalars.last == "\r" else { return line }
        return String(String.UnicodeScalarView(line.unicodeScalars.dropLast()))
    }

    private struct Header {
        let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        let context: String

        /// `@@ -oldStart[,oldCount] +newStart[,newCount] @@[ context]`
        init(_ line: String) throws {
            guard line.hasPrefix("@@ -"),
                  let close = line.range(of: " @@", range: line.index(line.startIndex, offsetBy: 4)..<line.endIndex)
            else { throw PatchError.malformedHeader(line) }

            let ranges = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound].split(separator: " ")
            guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+"),
                  let old = Self.range(ranges[0].dropFirst()), let new = Self.range(ranges[1].dropFirst())
            else { throw PatchError.malformedHeader(line) }

            (oldStart, oldCount) = old
            (newStart, newCount) = new
            let rest = line[close.upperBound...]
            context = String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
        }

        private static func range(_ text: Substring) -> (Int, Int)? {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let start = Int(parts[0]) else { return nil }
            guard parts.count == 2 else { return (start, 1) }
            guard let count = Int(parts[1]) else { return nil }
            return (start, count)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
