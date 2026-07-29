import Foundation
import Testing
@testable import PRMasterCore

/// These strings are the entire popover in a failure state, so they have to
/// tell the user what to do rather than what went wrong internally.
@Suite("Error messages")
struct ErrorMessageTests {

    @Test("setup failures name the exact command to run")
    func setupFailuresAreActionable() throws {
        let gh = try #require(PRMasterError.ghNotFound.errorDescription)
        #expect(gh.contains("brew install gh"))

        let auth = try #require(
            PRMasterError.notAuthenticated(detail: "code 1").errorDescription
        )
        #expect(auth.contains("gh auth login"))
        #expect(!auth.contains("code 1"), "diagnostics belong in logs, not the UI")

        let unauthorized = try #require(PRMasterError.unauthorized.errorDescription)
        #expect(unauthorized.contains("gh auth login"))
    }

    @Test("common transport failures read as plain language", arguments: [
        (URLError.Code.notConnectedToInternet, "No internet connection."),
        (URLError.Code.networkConnectionLost, "No internet connection."),
        (URLError.Code.timedOut, "GitHub timed out."),
        (URLError.Code.cannotFindHost, "Can't reach github.com."),
    ])
    func networkMessages(code: URLError.Code, expected: String) {
        #expect(PRMasterError.network(URLError(code)).errorDescription == expected)
    }

    /// The reported bug: the popover showed the whole DecodingError, down to
    /// "NSCocoaErrorDomain Code=3840" and the column the '<' was on.
    @Test("a decoding failure keeps the decoder's dump out of the popover")
    func decodingDumpStaysInternal() throws {
        let dump = """
            DecodingError.dataCorrupted: The given data was not valid JSON. \
            NSCocoaErrorDomain Code=3840 "Unexpected character '<' around line 1, column 1."
            """
        let message = try #require(PRMasterError.decoding(dump).errorDescription)
        #expect(!message.contains("NSCocoaErrorDomain"))
        #expect(!message.contains("DecodingError"))
        #expect(!message.contains("column 1"))
    }

    /// An HTML body is the one decoding failure with a cause the user can act
    /// on, so it gets a message that names it rather than a shrug.
    @Test("a non-JSON answer points at the network")
    func nonJSONBlamesTheNetwork() throws {
        let message = try #require(PRMasterError.notJSON.errorDescription)
        #expect(message.contains("proxy"))
    }

    @Test("an unusable status names the code", arguments: [403, 502])
    func httpStatusIsNamed(status: Int) throws {
        let message = try #require(PRMasterError.httpError(status: status).errorDescription)
        #expect(message.contains("\(status)"))
    }

    @Test("no message leaks a raw error domain")
    func noRawDomains() {
        let cases: [PRMasterError] = [
            .ghNotFound,
            .notAuthenticated(detail: "x"),
            .unauthorized,
            .network(URLError(.notConnectedToInternet)),
            .network(URLError(.timedOut)),
            .notJSON,
            .httpError(status: 502),
            .decoding("Error Domain=NSCocoaErrorDomain Code=3840"),
        ]
        for error in cases {
            let message = error.errorDescription ?? ""
            #expect(!message.contains("NSURLErrorDomain"))
            #expect(!message.contains("Error Domain"))
        }
    }

    /// GitHub's merge refusals are shown verbatim on purpose.
    @Test("merge rejections pass through untouched")
    func mergeRejectionVerbatim() {
        let message = "Head branch was modified. Review and try the merge again."
        #expect(PRMasterError.mergeRejected(message).errorDescription == message)
    }
}
