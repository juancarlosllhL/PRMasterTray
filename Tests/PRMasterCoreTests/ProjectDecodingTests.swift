import Foundation
import Testing
@testable import PRMasterCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

@Suite("Project decoding")
struct ProjectDecodingTests {

    /// Recent projects alone missed boards updated the same day; the organization list catches them.
    @Test("discovery lists each open project once, whichever way it was found")
    func discovery() throws {
        let projects = try ProjectDecoder.decodeProjects(try fixture("projects-discovery"))
        #expect(projects.map(\.id).sorted() == ["PVT_admin", "PVT_nostatus", "PVT_team", "PVT_user"])
    }

    @Test("a project keeps its Status field and its options in board order")
    func statusOptions() throws {
        let projects = try ProjectDecoder.decodeProjects(try fixture("projects-discovery"))
        let team = try #require(projects.first { $0.id == "PVT_team" })
        #expect(team.statusFieldID == "PVTSSF_team")
        #expect(team.options.map(\.name) == ["Backlog", "In Progress", "In Review", "Done"])
        #expect(team.owner == "acme")
        #expect(team.title == "Platform Board")
    }

    @Test("a project without a Status field has nothing to map")
    func noStatusField() throws {
        let projects = try ProjectDecoder.decodeProjects(try fixture("projects-discovery"))
        let roadmap = try #require(projects.first { $0.id == "PVT_nostatus" })
        #expect(roadmap.statusFieldID == nil)
        #expect(roadmap.options.isEmpty)
    }

    @Test("issues and pull requests decode; drafts and redacted items do not")
    func items() throws {
        let page = try ProjectDecoder.decodeItems(try fixture("project-items"), projectID: "PVT_team")
        #expect(page.items.map(\.id) == ["PVTI_issue", "PVTI_pull"])
        #expect(page.next == nil)
    }

    @Test("an issue item carries its Status, type, reference and closing pull requests")
    func issueItem() throws {
        let page = try ProjectDecoder.decodeItems(try fixture("project-items"), projectID: "PVT_team")
        let issue = try #require(page.items.first)
        #expect(issue.projectID == "PVT_team")
        #expect(issue.statusOptionID == "t-review")
        #expect(issue.statusName == "In Review")
        #expect(issue.statusChangedAt == ISO8601DateFormatter().date(from: "2026-10-10T09:00:00Z"))
        #expect(issue.typeName == "Task")
        #expect(issue.reference == "widget#42")
        #expect(issue.repo == "acme/widget")
        #expect(!issue.isPullRequest)
        #expect(issue.links.map(\.number) == [43])
    }

    @Test("a pull request item with no Status reads as one, with no option")
    func pullItem() throws {
        let page = try ProjectDecoder.decodeItems(try fixture("project-items"), projectID: "PVT_team")
        let pull = try #require(page.items.last)
        #expect(pull.isPullRequest)
        #expect(pull.statusOptionID == nil)
        #expect(pull.typeName == "Pull request")
    }

    @Test("a missing project scope says how to grant it")
    func scopeMissing() throws {
        #expect(throws: PRMasterError.projectScopeMissing) {
            try ProjectDecoder.decodeProjects(try fixture("project-scope-error"))
        }
        #expect(PRMasterError.projectScopeMissing.errorDescription?.contains("gh auth refresh -s project") == true)
    }

    /// The read:org scope is reported the same way, and is not this app's to fix here.
    @Test("a missing scope other than a project one stays a plain GitHub error")
    func otherScope() {
        let body = Data(#"{"errors":[{"type":"INSUFFICIENT_SCOPES","message":"requires one of the following scopes: ['read:org']"}]}"#.utf8)
        #expect(throws: PRMasterError.graphQL(["requires one of the following scopes: ['read:org']"])) {
            try ProjectDecoder.decodeProjects(body)
        }
    }

    @Test("a confirmed move decodes, an unconfirmed one does not")
    func statusUpdate() throws {
        try ProjectDecoder.decodeStatusUpdate(
            Data(#"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_issue"}}}}"#.utf8)
        )
        #expect(throws: PRMasterError.self) {
            try ProjectDecoder.decodeStatusUpdate(Data(#"{"data":{"updateProjectV2ItemFieldValue":null}}"#.utf8))
        }
    }
}
