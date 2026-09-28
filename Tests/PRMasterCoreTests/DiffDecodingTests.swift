import Foundation
import Testing
@testable import PRMasterCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

private func file(_ json: String) -> String {
    #"{"filename":"a.swift","status":"modified","additions":1,"deletions":1,"changes":2"# + json + "}"
}

@Suite("DiffDecoder")
struct DiffDecodingTests {

    @Test("a compare response from cli/cli#14516 decodes every file with its counts")
    func textFiles() throws {
        let files = try DiffDecoder.compareFiles(fixture("compare-text"))
        #expect(files.map(\.path) == [
            "internal/attachments/client.go",
            "internal/attachments/client_test.go",
            "skills/gh/SKILL.md",
        ])
        #expect(files.map(\.change) == [.modified, .modified, .modified])
        #expect(files[0].additions == 3)
        #expect(files[0].deletions == 1)
        #expect(files.allSatisfy { $0.viewed == .unviewed })
    }

    /// The parser is strict, so this is the proof it is not too strict: every
    /// patch GitHub actually returned in the fixtures must come out as hunks.
    @Test(
        "every real patch in the fixtures parses",
        arguments: ["compare-text", "compare-binary", "compare-renames"]
    )
    func realPatchesParse(name: String) throws {
        let files = try DiffDecoder.compareFiles(fixture(name))
        for file in files where file.additions + file.deletions > 0 {
            guard case .hunks(let hunks) = file.content else {
                Issue.record("\(file.path) did not parse: \(file.content)")
                continue
            }
            let added = hunks.flatMap(\.lines).filter { $0.kind == .added }.count
            #expect(added == file.additions, "\(file.path)")
        }
    }

    @Test("GitHub counts a binary file as zero changes, so it reads as having no text to show")
    func binary() throws {
        let files = try DiffDecoder.compareFiles(fixture("compare-binary"))
        let png = try #require(files.first { $0.path.hasSuffix(".png") })
        #expect(png.change == .added)
        #expect(png.content == .omitted(.noTextChanges))
    }

    @Test("a rename with edits keeps where it came from and its hunks")
    func renameWithPatch() throws {
        let files = try DiffDecoder.compareFiles(fixture("compare-renames"))
        #expect(files[0].change == .renamed)
        #expect(files[0].previousPath?.hasSuffix("chatDebugFileListRenderer.ts") == true)
        guard case .hunks = files[0].content else {
            Issue.record("expected hunks, got \(files[0].content)")
            return
        }
    }

    @Test("a pure rename keeps where it came from and has no text to show")
    func pureRename() throws {
        let files = try DiffDecoder.compareFiles(fixture("compare-renames"))
        #expect(files[1].change == .renamed)
        #expect(files[1].previousPath?.hasSuffix("imageUtils.ts") == true)
        #expect(files[1].content == .omitted(.noTextChanges))
    }

    @Test("a file with changes but no patch is one GitHub judged too large to include")
    func tooLarge() throws {
        let json = #"{"files":[{"filename":"big.json","status":"modified","additions":9000,"deletions":3000,"changes":12000}]}"#
        let files = try DiffDecoder.compareFiles(Data(json.utf8))
        #expect(files[0].content == .omitted(.tooLarge))
    }

    @Test("a patch that fails to parse costs only its own file")
    func unparseableIsLocal() throws {
        let json = #"{"files":["# + file(#","patch":"@@ -1 +1 @@\n-a\n+b\n+c""#)
            + "," + file(#","patch":"@@ -1 +1 @@\n-a\n+b""#) + "]}"
        let files = try DiffDecoder.compareFiles(Data(json.utf8))
        #expect(files[0].content == .omitted(.unparseable))
        guard case .hunks = files[1].content else {
            Issue.record("the second file should still parse")
            return
        }
    }

    @Test("a status GitHub adds later reads as a modification rather than failing the whole diff")
    func unknownStatus() throws {
        let json = #"{"files":[{"filename":"a","status":"transmogrified","additions":0,"deletions":0,"changes":0}]}"#
        #expect(try DiffDecoder.compareFiles(Data(json.utf8))[0].change == .modified)
    }

    @Test("the pull request files endpoint returns a bare array of the same shape")
    func pullFilesArray() throws {
        let json = "[" + file(#","patch":"@@ -1 +1 @@\n-a\n+b""#) + "]"
        let files = try DiffDecoder.pullFiles(Data(json.utf8))
        #expect(files.map(\.path) == ["a.swift"])
    }

    @Test("a body that is not the expected JSON is a decoding error")
    func notJSON() {
        #expect(throws: PRMasterError.self) { try DiffDecoder.compareFiles(Data("[]".utf8)) }
    }
}
