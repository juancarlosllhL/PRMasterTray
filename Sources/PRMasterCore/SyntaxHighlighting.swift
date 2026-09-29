import Foundation

public protocol SyntaxHighlighting: Sendable {
    /// Unchanged when the language is unknown or highlighting fails.
    func highlight(_ file: DiffFile, theme: SyntaxTheme) async -> DiffFile
}

/// Shiki theme names, as the bundled script knows them.
public enum SyntaxTheme: String, Sendable, CaseIterable {
    case light = "github-light-default"
    case dark = "github-dark-default"
    case lightHighContrast = "github-light-high-contrast"
    case darkHighContrast = "github-dark-high-contrast"
}

public struct TokenStyle: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let italic = TokenStyle(rawValue: 1)
    public static let bold = TokenStyle(rawValue: 2)
    public static let underline = TokenStyle(rawValue: 4)
}

/// A coloured span in UTF-16 units, so it maps straight onto an `NSRange`.
public struct TokenRange: Sendable, Equatable {
    public let location: Int
    public let length: Int
    public let colour: RGB
    public let style: TokenStyle

    public init(location: Int, length: Int, colour: RGB, style: TokenStyle = []) {
        self.location = location
        self.length = length
        self.colour = colour
        self.style = style
    }
}

public enum SyntaxLanguage {

    public static func forPath(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if let language = byFileName[name] { return language }
        return byExtension[(name as NSString).pathExtension.lowercased()]
    }

    static let byFileName: [String: String] = [
        "Dockerfile": "docker", "Containerfile": "docker",
        "Makefile": "make", "makefile": "make", "GNUmakefile": "make",
        "Gemfile": "ruby", "Rakefile": "ruby", "Podfile": "ruby",
    ]

    static let byExtension: [String: String] = [
        "swift": "swift", "go": "go",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "tsx",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "cs": "csharp", "py": "python", "json": "json", "yml": "yaml", "yaml": "yaml",
        "sh": "shellscript", "bash": "shellscript", "zsh": "shellscript",
        "md": "markdown", "markdown": "markdown", "html": "html", "htm": "html", "css": "css",
        "sql": "sql", "rs": "rust", "java": "java", "kt": "kotlin", "kts": "kotlin",
        "dockerfile": "docker", "toml": "toml", "tf": "hcl", "tfvars": "hcl", "hcl": "hcl",
        "xml": "xml", "plist": "xml", "csproj": "xml", "svg": "xml", "rb": "ruby",
        "c": "cpp", "h": "cpp", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "graphql": "graphql", "gql": "graphql", "mk": "make",
    ]
}
