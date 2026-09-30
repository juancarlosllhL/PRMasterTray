import Foundation
import Testing
@testable import PRMasterCore

/// The stub must outlive the call: its deinit unregisters the queued answers.
private func client(_ outcomes: [StubOutcome]) throws -> (JiraClient, StubSession) {
    let stub = StubSession(outcomes: outcomes)
    let credentials = try JiraCredentials(
        baseURL: "https://acme.atlassian.net", email: "a@b.com", apiToken: "tok"
    )
    return (JiraClient(credentials: credentials, session: stub.session), stub)
}

private func plain(_ id: String) -> JiraTransition {
    JiraTransition(id: id, to: JiraStatus(name: "Testing", category: .inProgress), isGlobal: false, needsInput: false)
}

private func ok(_ body: String) -> StubOutcome {
    .response(status: 200, body: Data(body.utf8))
}

/// Trimmed from the live answer for ACME-62565, a Bug in Reviewing.
private let reviewingBug = """
{"key":"ACME-62565","fields":{"status":{"name":"Reviewing","statusCategory":{"key":"indeterminate"}},
 "issuetype":{"id":"10004","name":"Bug"}},
 "transitions":[
  {"id":"21","name":"Canceled","isGlobal":true,"hasScreen":true,
   "to":{"name":"Canceled","statusCategory":{"key":"done"}},
   "fields":{"resolution":{"required":true,"name":"Resolution","schema":{"type":"resolution","system":"resolution"}}}},
  {"id":"71","name":"Testing","isGlobal":false,"hasScreen":true,
   "to":{"name":"Testing","statusCategory":{"key":"indeterminate"}},
   "fields":{
    "customfield_10346":{"required":false,"name":"Changelog status",
      "schema":{"type":"option","custom":"com.atlassian.jira.plugin.system.customfieldtypes:select"},
      "allowedValues":[{"value":"Internal","id":"1"},{"value":"External","id":"2"}]},
    "customfield_10039":{"required":false,"name":"Changelog",
      "schema":{"type":"string","custom":"com.atlassian.jira.plugin.system.customfieldtypes:textarea"}},
    "customfield_10170":{"required":false,"name":"Remark",
      "schema":{"type":"string","custom":"com.atlassian.jira.plugin.system.customfieldtypes:textarea"}}}},
  {"id":"51","name":"In Progress",
   "to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}
 ]}
"""

/// Trimmed from the live answer for LAN-22431, a Vulnerability in Reviewing.
private func testingScreen(issueType: String, changelogRequired: Bool) -> String {
    """
    {"fields":{"status":{"name":"Reviewing","statusCategory":{"key":"indeterminate"}},"issuetype":\(issueType)},
     "transitions":[{"id":"71","to":{"name":"Testing","statusCategory":{"key":"indeterminate"}},
      "fields":{
       "customfield_10346":{"required":false,"name":"Changelog status",
         "schema":{"type":"option","custom":"com.atlassian.jira.plugin.system.customfieldtypes:select"},
         "allowedValues":[{"value":"Internal"},{"value":"External"}]},
       "customfield_10039":{"required":\(changelogRequired),"name":"Changelog",
         "schema":{"type":"string","custom":"com.atlassian.jira.plugin.system.customfieldtypes:textarea"}}}}]}
    """
}

@Suite("JiraClient transitions")
struct JiraTransitionClientTests {

    @Test("one GET returns the live status with every transition")
    func readsTransitions() async throws {
        let (client, stub) = try client([ok(reviewingBug)])

        let (status, transitions) = try await client.transitions(for: "ACME-62565")

        #expect(status == JiraStatus(name: "Reviewing", category: .inProgress))
        #expect(transitions.map(\.id) == ["21", "71", "51"])
        #expect(transitions[1].to == JiraStatus(name: "Testing", category: .inProgress))
        #expect(transitions.map(\.isGlobal) == [true, false, false])

        let request = try #require(stub.requests.first)
        #expect(request.method == "GET")
        let url = try #require(request.url)
        #expect(url.path == "/rest/api/3/issue/ACME-62565")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "expand", value: "transitions.fields")))
        #expect(items.contains(URLQueryItem(name: "fields", value: "status,issuetype")))
    }

    @Test("the status id is read for the issue and for every destination")
    func readsStatusIDs() async throws {
        let body = """
        {"fields":{"status":{"id":"6","name":"Pruebas","statusCategory":{"key":"indeterminate"}}},
         "transitions":[{"id":"61","to":{"id":"1","name":"En revisión","statusCategory":{"key":"indeterminate"}}}]}
        """
        let (client, stub) = try client([ok(body)])
        let (status, transitions) = try await client.transitions(for: "ACME-63335")
        #expect(status == JiraStatus(name: "Pruebas", category: .inProgress, id: "6"))
        #expect(transitions.map(\.to.id) == ["1"])
        withExtendedLifetime(stub) {}
    }

    /// Jira calls all three optional, yet a validator demands them, so the app asks for every one.
    @Test("a screen's fields come back in a stable order with the kind of each")
    func readsScreenFields() async throws {
        let (client, stub) = try client([ok(reviewingBug)])
        let (_, transitions) = try await client.transitions(for: "ACME-62565")
        let fields = transitions[1].fields
        #expect(fields.map(\.name) == ["Changelog", "Remark", "Changelog status"])
        #expect(fields.map(\.kind) == [.richText, .richText, .option(["Internal", "External"])])
        #expect(transitions[0].fields.isEmpty, "a field the app cannot fill is not asked for")
        withExtendedLifetime(stub) {}
    }

    /// The Vulnerability workflow has no validator: half of those Done have no Changelog.
    @Test("a screen Jira calls optional asks nothing of a type other than Bug", arguments: [
        #"{"id":"10093","name":"Vulnerability"}"#, #"{"id":"10003","name":"Sub-task"}"#,
    ])
    func optionalScreenOutsideBugs(issueType: String) async throws {
        let (client, stub) = try client([ok(testingScreen(issueType: issueType, changelogRequired: false))])
        let (_, transitions) = try await client.transitions(for: "LAN-22431")
        #expect(transitions[0].fields.isEmpty)
        withExtendedLifetime(stub) {}
    }

    @Test("a field Jira itself requires is asked for on any type")
    func requiredOutsideBugs() async throws {
        let body = testingScreen(issueType: #"{"id":"10093","name":"Vulnerability"}"#, changelogRequired: true)
        let (client, stub) = try client([ok(body)])
        let (_, transitions) = try await client.transitions(for: "LAN-22431")
        #expect(transitions[0].fields.map(\.name) == ["Changelog"])
        withExtendedLifetime(stub) {}
    }

    @Test("a Bug is known by its type id, whatever the account's language calls it")
    func translatedBug() async throws {
        let (client, stub) = try client([ok(testingScreen(issueType: #"{"id":"10004","name":"Error"}"#, changelogRequired: false))])
        let (_, transitions) = try await client.transitions(for: "ACME-62565")
        #expect(transitions[0].fields.map(\.name) == ["Changelog", "Changelog status"])
        withExtendedLifetime(stub) {}
    }

    /// A screen alone is not a blocker. A required field the app cannot fill is.
    @Test("only a required field makes a transition need input")
    func requiredFieldsOnly() async throws {
        let (client, stub) = try client([ok(reviewingBug)])
        let (_, transitions) = try await client.transitions(for: "ACME-62565")
        #expect(transitions.map(\.needsInput) == [true, false, false])
        withExtendedLifetime(stub) {}
    }

    @Test("performing a transition posts its id and nothing else")
    func performs() async throws {
        let (client, stub) = try client([.response(status: 204, body: Data())])

        try await client.perform(plain("61"), on: "ACME-64471", values: [:])

        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.url?.path == "/rest/api/3/issue/ACME-64471/transitions")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Authorization"]?.hasPrefix("Basic ") == true)
        let body = try JSONSerialization.jsonObject(with: try #require(request.body))
        #expect(body as? NSDictionary == ["transition": ["id": "61"]])
    }

    @Test("screen values are posted in the shape each field needs")
    func postsFieldValues() async throws {
        let (client, stub) = try client([ok(reviewingBug), .response(status: 204, body: Data())])
        let (_, transitions) = try await client.transitions(for: "ACME-62565")

        try await client.perform(transitions[1], on: "ACME-62565", values: [
            "customfield_10346": "Internal",
            "customfield_10039": "Fixed the crash.",
            "customfield_10170": "PM: stale field in the query.",
        ])

        let body = try #require(stub.requests.last?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["transition"] as? [String: String] == ["id": "71"])
        let fields = try #require(json["fields"] as? [String: Any])
        #expect(fields["customfield_10346"] as? [String: String] == ["value": "Internal"])
        let remark = try #require(fields["customfield_10170"] as? [String: Any])
        #expect(remark["type"] as? String == "doc")
    }

    @Test("Jira's refusal is shown in its own words", arguments: [400, 403, 404, 409])
    func refusal(status: Int) async throws {
        let body = #"{"errorMessages":["Transition not allowed."],"errors":{"resolution":"Resolution is required."}}"#
        let (client, stub) = try client([.response(status: status, body: Data(body.utf8))])

        await #expect(throws: PRMasterError.jiraMoveRefused(
            "Transition not allowed. Resolution is required."
        )) {
            try await client.perform(plain("21"), on: "ACME-1", values: [:])
        }
        withExtendedLifetime(stub) {}
    }

    @Test("a refusal with no readable body still names the status")
    func refusalWithoutBody() async throws {
        let (client, stub) = try client([.response(status: 400, body: Data("<html>".utf8))])
        await #expect(throws: PRMasterError.jiraMoveRefused("Jira answered HTTP 400.")) {
            try await client.perform(plain("21"), on: "ACME-1", values: [:])
        }
        withExtendedLifetime(stub) {}
    }

    /// Read as unknown it would land in In progress and confirm a move that never happened.
    @Test("an answer without a status is a decoding failure", arguments: [
        #"{"fields":{},"transitions":[]}"#,
        #"{"fields":{"status":{"statusCategory":{"key":"new"}}},"transitions":[]}"#,
    ])
    func missingStatus(body: String) async throws {
        let (client, stub) = try client([ok(body)])
        await #expect {
            try await client.transitions(for: "ACME-1")
        } throws: { error in
            if case .decoding = error as? PRMasterError { return true }
            return false
        }
        withExtendedLifetime(stub) {}
    }

    @Test("a rejected token is still a sign-in problem")
    func unauthorized() async throws {
        let (client, stub) = try client([.response(status: 401, body: Data())])
        await #expect(throws: PRMasterError.jiraUnauthorized) {
            try await client.transitions(for: "ACME-1")
        }
        withExtendedLifetime(stub) {}
    }

    @Test("a key that is not a Jira key never reaches the network", arguments: [
        "", "acme-1", "ACME", "ACME-", "ACME-1/../../myself", "ACME-1?x=1", "-1",
    ])
    func malformedKey(key: String) async throws {
        let (client, stub) = try client([])
        await #expect(throws: PRMasterError.self) {
            try await client.perform(plain("61"), on: key, values: [:])
        }
        #expect(stub.requests.isEmpty)
    }
}
