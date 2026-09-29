import Foundation
import JavaScriptCore

/// Runs the bundled Shiki script. One context, used by one caller at a time.
public actor ShikiHighlighter: SyntaxHighlighting {

    public enum LoadError: Error, Equatable {
        case script(String)
        case missingEntryPoint
    }

    private let context: JSContext
    private let entryPoint: JSValue

    public init(script: String) throws {
        guard let context = JSContext() else { throw LoadError.missingEntryPoint }
        context.evaluateScript(script)
        if let exception = context.exception { throw LoadError.script(exception.toString() ?? "") }
        guard let entryPoint = context.objectForKeyedSubscript("prmaster"),
              entryPoint.forProperty("highlight")?.isObject == true
        else { throw LoadError.missingEntryPoint }
        self.context = context
        self.entryPoint = entryPoint
    }

    public func languages() -> [String] {
        call("languages", [])?.toArray() as? [String] ?? []
    }

    public func highlight(_ file: DiffFile, theme: SyntaxTheme) -> DiffFile {
        guard case .hunks(let hunks) = file.content, let language = SyntaxLanguage.forPath(file.path) else {
            return file
        }
        let sides = hunks.map(HunkSides.init)
        let segments = sides.flatMap { [$0.oldTexts, $0.newTexts] }
        guard let ranges = ranges(for: segments, language: language, theme: theme) else { return file }

        let highlighted = zip(hunks, sides).enumerated().map { position, pair in
            pair.1.apply(old: ranges[position * 2], new: ranges[position * 2 + 1], to: pair.0)
        }
        return DiffFile(
            path: file.path, previousPath: file.previousPath, change: file.change,
            additions: file.additions, deletions: file.deletions, content: .hunks(highlighted), viewed: file.viewed
        )
    }

    private struct Payload: Decodable {
        let colours: [String]
        let segments: [[[Int]]?]
    }

    /// Nil unless every segment comes back with one range list per line.
    private func ranges(for segments: [[String]], language: String, theme: SyntaxTheme) -> [[[TokenRange]]]? {
        guard let json = call("highlight", [segments, language, theme.rawValue])?.toString(),
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)),
              payload.segments.count == segments.count
        else { return nil }
        let colours = payload.colours.map(RGB.init(css:))

        var result: [[[TokenRange]]] = []
        for (texts, lines) in zip(segments, payload.segments) {
            guard let lines, lines.count == texts.count else { return nil }
            result.append(zip(texts, lines).map { text, flat in Self.decode(flat, colours: colours, width: text.utf16.count) })
        }
        return result
    }

    private static func decode(_ flat: [Int], colours: [RGB?], width: Int) -> [TokenRange] {
        stride(from: 0, to: flat.count - flat.count % 4, by: 4).compactMap { at in
            let location = flat[at], length = flat[at + 1], index = flat[at + 2]
            guard location >= 0, length > 0, location + length <= width,
                  colours.indices.contains(index), let colour = colours[index]
            else { return nil }
            return TokenRange(location: location, length: length, colour: colour, style: TokenStyle(rawValue: flat[at + 3]))
        }
    }

    private func call(_ method: String, _ arguments: [Any]) -> JSValue? {
        let value = entryPoint.invokeMethod(method, withArguments: arguments)
        if context.exception != nil {
            context.exception = nil
            return nil
        }
        return value?.isUndefined == false ? value : nil
    }
}

/// A hunk read as the two files it comes from, so a comment opened on one side stays there.
private struct HunkSides {
    let oldIndices: [Int]
    let newIndices: [Int]
    let oldTexts: [String]
    let newTexts: [String]

    init(_ hunk: Hunk) {
        oldIndices = hunk.lines.indices.filter { hunk.lines[$0].kind != .added }
        newIndices = hunk.lines.indices.filter { hunk.lines[$0].kind != .removed }
        oldTexts = oldIndices.map { hunk.lines[$0].text }
        newTexts = newIndices.map { hunk.lines[$0].text }
    }

    func apply(old: [[TokenRange]], new: [[TokenRange]], to hunk: Hunk) -> Hunk {
        var lines = hunk.lines
        for (position, index) in oldIndices.enumerated() where lines[index].kind == .removed {
            lines[index].tokens = old[position]
        }
        for (position, index) in newIndices.enumerated() {
            lines[index].tokens = new[position]
        }
        return Hunk(
            oldStart: hunk.oldStart, oldCount: hunk.oldCount, newStart: hunk.newStart,
            newCount: hunk.newCount, context: hunk.context, lines: lines
        )
    }
}

extension RGB {
    /// `#RRGGBB`, ignoring any alpha. Nil for anything else.
    init?(css: String) {
        let digits = css.hasPrefix("#") ? String(css.dropFirst().prefix(6)) : ""
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self = .hex(value)
    }
}
