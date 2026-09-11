import Foundation
import Testing
@testable import PRMasterCore

private struct Call: Sendable, Equatable {
    let arguments: [String]
    let input: String?
}

private final class Runs: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _answers: [Keychain.RunResult]

    init(answers: [Keychain.RunResult]) { _answers = answers }

    var calls: [Call] { lock.withLock { _calls } }

    func next(_ arguments: [String], _ input: String?) -> Keychain.RunResult {
        lock.withLock {
            _calls.append(Call(arguments: arguments, input: input))
            return _answers.isEmpty
                ? Keychain.RunResult(stdout: "", exitCode: 0)
                : _answers.removeFirst()
        }
    }
}

private func makeKeychain(
    _ answers: [Keychain.RunResult] = []
) -> (Keychain, Runs) {
    let runs = Runs(answers: answers)
    let keychain = Keychain(
        service: "svc", account: "acct",
        run: { arguments, input in runs.next(arguments, input) }
    )
    return (keychain, runs)
}

private func ok(_ stdout: String) -> Keychain.RunResult {
    Keychain.RunResult(stdout: stdout, exitCode: 0)
}

private func failing(_ code: Int32) -> Keychain.RunResult {
    Keychain.RunResult(stdout: "", exitCode: code)
}

/// An app signed by anything but Apple gets a partition list keyed on its code
/// hash, which changes with every build and re-asks for the login password.
/// Apple's own tool is anchored, so the item it owns stays readable.
@Suite("Keychain commands")
struct KeychainCommandTests {

    @Test("reading asks security for the item")
    func readArguments() throws {
        let (keychain, runs) = makeKeychain([ok("aGk=\n")])
        _ = try keychain.read()
        #expect(runs.calls == [Call(
            arguments: ["find-generic-password", "-s", "svc", "-a", "acct", "-w"],
            input: nil
        )])
    }

    @Test("a missing item reads as nil rather than throwing")
    func missingIsNil() throws {
        let (keychain, _) = makeKeychain([failing(Keychain.itemNotFound)])
        #expect(try keychain.read() == nil)
    }

    @Test("any other failure to read is an error")
    func readFailureThrows() throws {
        let (keychain, _) = makeKeychain([failing(1)])
        #expect(throws: PRMasterError.jiraKeychainFailure(status: 1)) {
            try keychain.read()
        }
    }

    @Test("the trailing newline security adds is not part of the value")
    func readStripsNewline() throws {
        let (keychain, _) = makeKeychain([ok("aGVsbG8=\n")])
        #expect(try keychain.read() == "hello")
    }

    /// An item written by a version that stored plain text would otherwise be
    /// reported as absent, which reads as "you were never signed in".
    @Test("a value that is not base64 comes back unchanged")
    func readPassesThroughPlainText() throws {
        let (keychain, _) = makeKeychain([ok(#"{"baseUrl":"x"}"# + "\n")])
        #expect(try keychain.read() == #"{"baseUrl":"x"}"#)
    }

    /// Standard input would be the safer channel, but security reads at most
    /// 128 characters there and a sign-in is longer than that.
    @Test("writing passes the value as an argument, encoded")
    func writeEncodesTheValue() throws {
        let (keychain, runs) = makeKeychain()
        try keychain.write("hello")
        #expect(runs.calls.last?.arguments.last == "aGVsbG8=")
        #expect(runs.calls.last?.input == nil)
    }

    @Test("a value far longer than a prompt allows is passed whole")
    func writeDoesNotTruncate() throws {
        let (keychain, runs) = makeKeychain()
        let value = String(repeating: "a", count: 400)
        try keychain.write(value)
        #expect(runs.calls.last?.arguments.last == Data(value.utf8).base64EncodedString())
    }

    /// An item left by an earlier build belongs to a code hash security cannot
    /// satisfy, so updating it in place would ask for the login password.
    @Test("writing replaces any existing item rather than updating it")
    func writeDeletesFirst() throws {
        let (keychain, runs) = makeKeychain([failing(Keychain.itemNotFound), ok("")])
        try keychain.write("hello")
        #expect(runs.calls.count == 2)
        #expect(runs.calls.first?.arguments.first == "delete-generic-password")
        #expect(runs.calls.last?.arguments == [
            "add-generic-password", "-s", "svc", "-a", "acct", "-w", "aGVsbG8=",
        ])
    }

    @Test("a failure to write is an error")
    func writeFailureThrows() throws {
        let (keychain, _) = makeKeychain([failing(Keychain.itemNotFound), failing(45)])
        #expect(throws: PRMasterError.jiraKeychainFailure(status: 45)) {
            try keychain.write("hello")
        }
    }

    @Test("deleting asks security to remove the item")
    func deleteArguments() throws {
        let (keychain, runs) = makeKeychain()
        try keychain.delete()
        #expect(runs.calls == [Call(
            arguments: ["delete-generic-password", "-s", "svc", "-a", "acct"],
            input: nil
        )])
    }

    /// Sign-out runs whether or not anything was stored.
    @Test("deleting something absent is not an error")
    func deleteAbsentIsFine() throws {
        let (keychain, _) = makeKeychain([failing(Keychain.itemNotFound)])
        try keychain.delete()
    }

    @Test("any other failure to delete is an error")
    func deleteFailureThrows() throws {
        let (keychain, _) = makeKeychain([failing(1)])
        #expect(throws: PRMasterError.jiraKeychainFailure(status: 1)) {
            try keychain.delete()
        }
    }
}
