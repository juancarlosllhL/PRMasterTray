import Foundation
import Testing
@testable import PRMasterCore

@Suite("PullRequestDecoder.decodeIssueLinks")
struct JiraLinkDecodingTests {

    private static func node(_ number: Int, _ repo: String, _ state: String) -> String {
        """
        {"id":"PR_\(number)","number":\(number),"title":"ACME-1 something",
         "url":"https://github.com/\(repo)/pull/\(number)","state":"\(state)","isDraft":false,
         "repository":{"nameWithOwner":"\(repo)","isPrivate":false}}
        """
    }

    /// The alias index is the only thing tying a result back to the key that
    /// asked for it, so a mis-mapping would nest pull requests under the wrong
    /// issue without any error.
    @Test("results map back to the key by alias index")
    func mapsByAliasIndex() throws {
        let json = """
        {"data":{
          "k0":{"nodes":[\(Self.node(1, "acme/one", "OPEN"))]},
          "k1":{"nodes":[]},
          "k2":{"nodes":[\(Self.node(2, "acme/two", "MERGED")),\(Self.node(3, "acme/three", "OPEN"))]}
        }}
        """
        let links = try PullRequestDecoder.decodeIssueLinks(
            Data(json.utf8), keys: ["ACME-1", "ACME-2", "ACME-3"]
        )

        #expect(links["ACME-1"]?.map(\.number) == [1])
        #expect(links["ACME-2"] == [])
        #expect(links["ACME-3"]?.map(\.number) == [2, 3])
    }

    /// An issue with no pull requests must decode to an empty list, not a
    /// missing key: absent would read as "not looked up yet", which is a
    /// different thing the UI must not conflate with "none exist".
    @Test("a key with no results is present and empty")
    func emptyIsPresentNotAbsent() throws {
        let json = #"{"data":{"k0":{"nodes":[]}}}"#
        let links = try PullRequestDecoder.decodeIssueLinks(Data(json.utf8), keys: ["ACME-1"])

        #expect(links["ACME-1"] != nil)
        #expect(links["ACME-1"]?.isEmpty == true)
    }

    @Test("state and draft decode", arguments: [
        ("OPEN", LinkedPullRequestState.open),
        ("MERGED", LinkedPullRequestState.merged),
        ("CLOSED", LinkedPullRequestState.closed),
    ])
    func stateDecodes(raw: String, expected: LinkedPullRequestState) throws {
        let json = #"{"data":{"k0":{"nodes":[\#(Self.node(1, "acme/one", raw))]}}}"#
        let links = try PullRequestDecoder.decodeIssueLinks(Data(json.utf8), keys: ["ACME-1"])
        #expect(links["ACME-1"]?.first?.state == expected)
    }

    /// A state GitHub adds later must not be read as merged, which would tell
    /// the user work had shipped when it had not.
    @Test("an unrecognised state is not merged")
    func unknownStateIsNotMerged() throws {
        let json = #"{"data":{"k0":{"nodes":[\#(Self.node(1, "acme/one", "TRANSMOGRIFIED"))]}}}"#
        let links = try PullRequestDecoder.decodeIssueLinks(Data(json.utf8), keys: ["ACME-1"])
        #expect(links["ACME-1"]?.first?.state != .merged)
    }

    /// SSO and scope failures arrive as HTTP 200 with a populated errors array,
    /// which must not be read as "this issue has no pull requests".
    @Test("an errors array throws rather than decoding as empty")
    func errorsThrow() {
        let json = #"{"data":null,"errors":[{"message":"SAML enforcement"}]}"#
        #expect(throws: (any Error).self) {
            try PullRequestDecoder.decodeIssueLinks(Data(json.utf8), keys: ["ACME-1"])
        }
    }
}
