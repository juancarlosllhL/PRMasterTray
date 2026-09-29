import Foundation

/// Reads the `linguist-generated` marks GitHub itself uses to collapse generated
/// files, which its API never reports.
enum GitAttributes {

    /// A `!` rule for each path un-marked with `-`, `!` or `=false`.
    static func generatedRules(in text: String) -> GlobList {
        var lines: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let pattern = fields.first, !pattern.hasPrefix("#"), !pattern.hasPrefix("!"), !pattern.hasPrefix("[attr]") else {
                continue
            }
            for attribute in fields.dropFirst() {
                switch attribute {
                case "linguist-generated", "linguist-generated=true": lines.append(pattern)
                case "-linguist-generated", "!linguist-generated", "linguist-generated=false": lines.append("!" + pattern)
                default: continue
                }
            }
        }
        return GlobList(lines: lines)
    }
}
