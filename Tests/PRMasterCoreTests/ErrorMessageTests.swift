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

    @Test("no message leaks a raw error domain")
    func noRawDomains() {
        let cases: [PRMasterError] = [
            .ghNotFound,
            .notAuthenticated(detail: "x"),
            .unauthorized,
            .network(URLError(.notConnectedToInternet)),
            .network(URLError(.timedOut)),
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
