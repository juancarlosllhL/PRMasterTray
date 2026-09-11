import Foundation
import Testing
@testable import PRMasterCore

@Suite("JiraSignInState")
struct JiraSignInStateTests {

    @Test("the state set is exhaustive")
    func stateSetIsExhaustive() {
        #expect(JiraSignInState.allCases.count == 4)
    }

    @Test("a fresh form is idle")
    func freshIsIdle() {
        #expect(JiraSignInState.idle.isBusy == false)
        #expect(JiraSignInState.idle.succeededName == nil)
    }

    @Test("only testing is busy", arguments: JiraSignInState.allCases)
    func onlyTestingIsBusy(state: JiraSignInState) {
        #expect(state.isBusy == (state == .testing))
    }

    @Test("success carries the name it signed in as")
    func successCarriesName() {
        #expect(JiraSignInState.succeeded(name: "Ada").succeededName == "Ada")
        #expect(JiraSignInState.failed(message: "no").succeededName == nil)
    }

    /// Verified live: a bad token, a wrong email and outright garbage all
    /// answer with the same 401 and the same body. Blaming one field would be
    /// a guess the API does not support.
    @Test("401 blames the pair, never a single field")
    func unauthorizedBlamesThePair() {
        let message = JiraSignInState.message(for: .jiraUnauthorized)

        #expect(message.lowercased().contains("email"))
        #expect(message.lowercased().contains("token"))
        #expect(!message.lowercased().contains("invalid token"))
        #expect(!message.lowercased().contains("wrong password"))
    }

    /// A token is created at id.atlassian.com, and somebody who has never made
    /// one cannot be expected to guess that.
    @Test("the 401 message says where to get a token")
    func unauthorizedPointsAtTheTokenPage() {
        #expect(JiraSignInState.message(for: .jiraUnauthorized).contains("id.atlassian.com"))
    }

    @Test("other failures keep their own wording", arguments: [
        PRMasterError.jiraInvalidCredentials(detail: "The API token is empty."),
        PRMasterError.httpError(status: 500),
        PRMasterError.network(URLError(.notConnectedToInternet)),
    ])
    func otherFailuresKeepWording(error: PRMasterError) {
        let message = JiraSignInState.message(for: error)
        #expect(!message.isEmpty)
        #expect(message == error.localizedDescription)
    }

    /// The raw domain leak this repo already guards against elsewhere.
    @Test("no message leaks a raw error domain", arguments: [
        PRMasterError.jiraUnauthorized,
        PRMasterError.network(URLError(.timedOut)),
        PRMasterError.jiraKeychainFailure(status: -25300),
    ])
    func noRawDomains(error: PRMasterError) {
        let message = JiraSignInState.message(for: error)
        #expect(!message.contains("NSURLError"))
        #expect(!message.contains("Error Domain"))
        #expect(!message.contains("PRMasterCore."))
    }
}
