import Foundation
import Testing
@testable import PRMasterCore

/// Records probe order across the @Sendable closures the provider takes.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _probed: [String] = []
    private var _ran: [String] = []

    var probed: [String] { lock.withLock { _probed } }
    var ran: [String] { lock.withLock { _ran } }

    func probe(_ path: String) { lock.withLock { _probed.append(path) } }
    func run(_ path: String) { lock.withLock { _ran.append(path) } }
}

private func makeProvider(
    paths: [String],
    existing: Set<String>,
    stdout: String = "gho_faketokenvalue",
    exitCode: Int32 = 0,
    recorder: Recorder = Recorder()
) -> (TokenProvider, Recorder) {
    let provider = TokenProvider(
        paths: paths,
        fileExists: { path in
            recorder.probe(path)
            return existing.contains(path)
        },
        run: { path in
            recorder.run(path)
            return TokenProvider.RunResult(stdout: stdout, exitCode: exitCode)
        }
    )
    return (provider, recorder)
}

@Suite("TokenProvider")
struct TokenProviderTests {

    @Test("probes the known gh locations in order")
    func probesInOrder() throws {
        let paths = ["/a/gh", "/b/gh", "/c/gh"]
        let (provider, recorder) = makeProvider(paths: paths, existing: ["/c/gh"])
        _ = try provider.token()
        #expect(recorder.probed == paths)
    }

    @Test("uses the first path that exists and stops there")
    func firstExistingWins() throws {
        let (provider, recorder) = makeProvider(
            paths: ["/a/gh", "/b/gh", "/c/gh"],
            existing: ["/b/gh", "/c/gh"]
        )
        _ = try provider.token()
        #expect(recorder.ran == ["/b/gh"])
        #expect(recorder.probed == ["/a/gh", "/b/gh"])
    }

    @Test("throws ghNotFound when no candidate exists")
    func noBinary() {
        let (provider, _) = makeProvider(paths: ["/a/gh", "/b/gh"], existing: [])
        #expect(throws: PRMasterError.ghNotFound) {
            _ = try provider.token()
        }
    }

    @Test("trims trailing whitespace from the token")
    func trimsToken() throws {
        let (provider, _) = makeProvider(
            paths: ["/a/gh"], existing: ["/a/gh"],
            stdout: "  gho_faketokenvalue\n\n"
        )
        #expect(try provider.token() == "gho_faketokenvalue")
    }

    @Test("treats blank output as not authenticated", arguments: ["", "   ", "\n"])
    func blankOutput(stdout: String) {
        let (provider, _) = makeProvider(paths: ["/a/gh"], existing: ["/a/gh"], stdout: stdout)
        #expect(throws: PRMasterError.self) {
            _ = try provider.token()
        }
    }

    @Test("treats a non-zero exit as not authenticated")
    func nonZeroExit() {
        let (provider, _) = makeProvider(
            paths: ["/a/gh"], existing: ["/a/gh"],
            stdout: "gho_faketokenvalue", exitCode: 1
        )
        #expect(throws: PRMasterError.self) {
            _ = try provider.token()
        }
    }

    /// The failure diagnostic must be useful without becoming a way to leak the
    /// credential into logs or a crash report.
    @Test("reports the exit code but never the captured output")
    func neverLeaksStdout() {
        let secret = "gho_supersecretvalue"
        let (provider, _) = makeProvider(
            paths: ["/a/gh"], existing: ["/a/gh"],
            stdout: secret, exitCode: 42
        )
        do {
            _ = try provider.token()
            Issue.record("expected a throw")
        } catch let error as PRMasterError {
            guard case .notAuthenticated(let detail) = error else {
                Issue.record("expected .notAuthenticated, got \(error)")
                return
            }
            #expect(detail.contains("42"))
            #expect(!detail.contains(secret))
            #expect(!String(describing: error).contains(secret))
            // The user-facing message must stay actionable and secret-free.
            let shown = try! #require(error.errorDescription)
            #expect(shown.contains("gh auth login"))
            #expect(!shown.contains(secret))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("defaults cover the real gh install locations")
    func defaultPaths() {
        #expect(TokenProvider.defaultPaths.contains("/opt/homebrew/bin/gh"))
        #expect(TokenProvider.defaultPaths.contains("/usr/local/bin/gh"))
        #expect(TokenProvider.defaultPaths.contains("/usr/bin/gh"))
        // GUI apps do not inherit the shell PATH, so ~ must already be expanded.
        #expect(TokenProvider.defaultPaths.contains { $0.hasSuffix("/.local/bin/gh") })
        #expect(!TokenProvider.defaultPaths.contains { $0.hasPrefix("~") })
    }
}
