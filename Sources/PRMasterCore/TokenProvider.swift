import Foundation

/// Borrows the GitHub token from the `gh` CLI.
///
/// PRMaster deliberately stores no credential of its own: the token is read
/// fresh at each launch and held only in memory, so there is nothing on disk
/// or in the Keychain for this app to leak.
public struct TokenProvider: Sendable {

    public struct RunResult: Sendable {
        public let stdout: String
        public let exitCode: Int32

        public init(stdout: String, exitCode: Int32) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    /// A launched `.app` does not inherit the shell PATH, so Homebrew's `gh`
    /// is invisible unless we look for it explicitly. Ordered most to least
    /// likely on a developer Mac.
    public static let defaultPaths: [String] = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/gh"),
    ]

    private let paths: [String]
    private let fileExists: @Sendable (String) -> Bool
    private let run: @Sendable (String) throws -> RunResult

    public init(
        paths: [String] = TokenProvider.defaultPaths,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        run: @escaping @Sendable (String) throws -> RunResult = TokenProvider.execute
    ) {
        self.paths = paths
        self.fileExists = fileExists
        self.run = run
    }

    /// - Throws: `.ghNotFound` when no candidate binary exists, or
    ///   `.notAuthenticated` when `gh` runs but yields no usable token.
    public func token() throws -> String {
        guard let binary = paths.first(where: fileExists) else {
            throw PRMasterError.ghNotFound
        }

        let result = try run(binary)
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard result.exitCode == 0 else {
            // The exit code is safe to record; stdout is not — on success it
            // *is* the token, and on failure it may still hold fragments.
            throw PRMasterError.notAuthenticated(
                detail: "gh auth token exited with code \(result.exitCode)"
            )
        }
        guard !token.isEmpty else {
            throw PRMasterError.notAuthenticated(detail: "gh auth token returned no output")
        }

        return token
    }

    /// Default runner: `<binary> auth token`.
    public static func execute(_ binary: String) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["auth", "token"]

        let out = Pipe()
        process.standardOutput = out
        // Discard stderr rather than merging it: gh writes advisory notices
        // there, and merging risks them being mistaken for a token.
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(
            stdout: String(decoding: data, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}
