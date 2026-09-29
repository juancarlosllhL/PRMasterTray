import Foundation

public enum GlobError: Error, Equatable, Sendable {
    case empty, unbalancedBrace, unbalancedBracket
}

/// One `.gitignore`-style pattern, matched against a repository-relative path.
/// Case-sensitive, like git. Also accepts `{a,b}`, which git does not.
public struct Glob: Sendable, Equatable {
    public let source: String
    public let negated: Bool
    private let regex: NSRegularExpression

    public init(_ pattern: String) throws(GlobError) {
        source = pattern
        var body = Substring(pattern)
        negated = body.hasPrefix("!")
        if negated { body = body.dropFirst() }
        let directoryOnly = body.hasSuffix("/")
        if directoryOnly { body = body.dropLast() }
        let anchored = body.contains("/")
        if body.hasPrefix("/") { body = body.dropFirst() }
        guard !body.isEmpty else { throw .empty }

        let prefix = anchored ? "^" : "^(?:.*/)?"
        let suffix = directoryOnly ? "/.*$" : "(?:/.*)?$"
        let translated = try Self.translate(body)
        // Every piece is escaped or built here, so the expression always compiles.
        regex = try! NSRegularExpression(pattern: prefix + translated + suffix)
    }

    public func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    public static func == (lhs: Glob, rhs: Glob) -> Bool { lhs.source == rhs.source }

    private static func translate(_ body: Substring) throws(GlobError) -> String {
        let chars = Array(body)
        var out = ""
        var braceDepth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            let atSegmentStart = index == 0 || chars[index - 1] == "/"
            switch char {
            case "*" where index + 1 < chars.count && chars[index + 1] == "*" && atSegmentStart:
                let atEnd = index + 2 == chars.count
                if atEnd {
                    out += ".*"
                    index += 2
                } else if chars[index + 2] == "/" {
                    out += "(?:.*/)?"
                    index += 3
                } else {
                    out += "[^/]*"
                    index += 2
                }
                continue
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            case "[":
                guard let close = chars[(index + 1)...].firstIndex(of: "]"), close > index + 1 else {
                    throw .unbalancedBracket
                }
                var set = String(chars[(index + 1)..<close])
                if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                out += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                index = close
            case "{":
                braceDepth += 1
                out += "(?:"
            case "}" where braceDepth > 0:
                braceDepth -= 1
                out += ")"
            case "," where braceDepth > 0:
                out += "|"
            case "\\" where index + 1 < chars.count:
                index += 1
                out += NSRegularExpression.escapedPattern(for: String(chars[index]))
            default:
                out += NSRegularExpression.escapedPattern(for: String(char))
            }
            index += 1
        }
        guard braceDepth == 0 else { throw .unbalancedBrace }
        return out
    }
}

/// A list of patterns in settings order: blank lines and `#` comments are
/// skipped, and the last pattern that matches decides, as in `.gitignore`.
public struct GlobList: Sendable, Equatable {
    public let globs: [Glob]
    public let invalidLines: [String]

    public init(lines: [String]) {
        var globs: [Glob] = []
        var invalid: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            do { globs.append(try Glob(trimmed)) } catch { invalid.append(trimmed) }
        }
        self.globs = globs
        self.invalidLines = invalid
    }

    /// True when included, false when a `!` rule re-included it, nil when no rule applies.
    public func verdict(for path: String) -> Bool? {
        globs.last { $0.matches(path) }.map { !$0.negated }
    }
}
