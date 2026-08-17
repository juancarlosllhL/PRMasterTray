import Foundation
import Testing
@testable import PRMasterCore

@Suite("Promotion file")
struct PromotionFileTests {

    // MARK: which file carries a promoted version

    /// Kargo writes into the region-qualified file, so that is the only shape
    /// that can carry a promotion.
    @Test("a region-qualified file names its environment and region", arguments: [
        ("values.stg.euw1.yaml", DeployEnvironment.staging, "euw1"),
        ("values.stg.use2.yaml", .staging, "use2"),
        ("values.prd.euw1.yaml", .production, "euw1"),
        ("values.prd.use2.yaml", .production, "use2"),
    ])
    func regionQualifiedFiles(name: String, environment: DeployEnvironment, region: String) throws {
        let file = try #require(PromotionFile.parse(name: name))
        #expect(file.environment == environment)
        #expect(file.region == region)
    }

    /// Apps pinned to the central clusters spell the same two environments
    /// `cst` and `cpr`. Reading those as unknown would silently hide every
    /// central app — the embeddings one included.
    @Test("the central cluster codes are the same two environments", arguments: [
        ("values.cst.euw1.yaml", DeployEnvironment.staging),
        ("values.cpr.euw1.yaml", .production),
    ])
    func centralClusterCodes(name: String, environment: DeployEnvironment) throws {
        let file = try #require(PromotionFile.parse(name: name))
        #expect(file.environment == environment)
    }

    /// `values.yaml` holds `stableVersion: 0.0.0`, a placeholder that would read
    /// as a real promotion of version zero. Rejecting the filename is what makes
    /// that value unreachable, so no later stage has to special-case it.
    @Test("the base and env-wide files are not promotions", arguments: [
        "values.yaml", "values.stg.yaml", "values.prd.yaml", "values.cpr.yaml",
    ])
    func nonPromotionFiles(name: String) {
        #expect(PromotionFile.parse(name: name) == nil)
    }

    /// An environment code this app does not recognise must not be guessed into
    /// staging or production — naming the wrong environment is worse than
    /// naming none.
    @Test("an unrecognised environment code yields nothing", arguments: [
        "values.dev.euw1.yaml", "values.qa.euw1.yaml", "values.sandbox.use2.yaml",
    ])
    func unknownEnvironmentCode(name: String) {
        #expect(PromotionFile.parse(name: name) == nil)
    }

    @Test("an unrelated file in the app folder is not a promotion", arguments: [
        "Chart.yaml", "catalog-info.yaml", "values.stg.euw1.yml", "README.md",
    ])
    func unrelatedFiles(name: String) {
        #expect(PromotionFile.parse(name: name) == nil)
    }

    // MARK: reading the version out of the text

    @Test("the promoted version is read from the top-level key")
    func readsTopLevelKey() {
        let text = """
        stableVersion: 3.32.0
        host: eu.lansweeperdev.com
        """
        #expect(PromotionFile.stableVersion(in: text) == "3.32.0")
    }

    /// The real production values file carries a long comment that argues about
    /// which version must stay pinned, and the word appears inside it. Anchoring
    /// at column 0 is what keeps prose from being read as a promotion.
    @Test("a mention inside a comment is not the promoted version")
    func ignoresCommentaryMentions() {
        let text = """
        # Keep stableVersion >= 3.20.1 here; a rollback below that would crash-loop
        # the worker. That fix ships in 3.20.1, which is the stableVersion above.
        stableVersion: 3.31.1
        enableCustomDebugLogs: true
        """
        #expect(PromotionFile.stableVersion(in: text) == "3.31.1")
    }

    /// The case that would be worst to get wrong: a file that only ever argues
    /// about a version must report none, not the number it happens to mention.
    @Test("a file whose only mention is commentary yields nothing")
    func commentaryAloneYieldsNothing() {
        let text = """
        # Keep stableVersion >= 3.20.1 here; a rollback below that crash-loops.
        # That fix ships in 3.20.1, which is the stableVersion above.
        enableCustomDebugLogs: true
        """
        #expect(PromotionFile.stableVersion(in: text) == nil)
    }

    /// A nested key of the same name belongs to some sub-chart, not to the app.
    @Test("an indented key of the same name is ignored")
    func ignoresIndentedKey() {
        let text = """
        someSubChart:
          stableVersion: 9.9.9
        """
        #expect(PromotionFile.stableVersion(in: text) == nil)
    }

    @Test("a file with no such key yields nothing")
    func missingKey() {
        #expect(PromotionFile.stableVersion(in: "host: eu.lansweeper.com") == nil)
    }

    @Test("a key with no value yields nothing rather than an empty version")
    func emptyValue() {
        #expect(PromotionFile.stableVersion(in: "stableVersion:") == nil)
        #expect(PromotionFile.stableVersion(in: "stableVersion:   ") == nil)
    }

    /// Kargo writes the value bare, but a hand-edited file may quote it or
    /// explain itself. Either would otherwise produce a version string that
    /// matches no release tag and silently resolve to nothing.
    @Test("quoting and trailing commentary do not become part of the version", arguments: [
        ("stableVersion: \"3.32.0\"", "3.32.0"),
        ("stableVersion: '3.32.0'", "3.32.0"),
        ("stableVersion: 3.32.0 # pinned by hand, see ACME-58723", "3.32.0"),
    ])
    func trimsQuotesAndComments(line: String, expected: String) {
        #expect(PromotionFile.stableVersion(in: line) == expected)
    }

    /// Windows line endings would otherwise leave a carriage return glued to the
    /// version, which no tag would ever match.
    @Test("a carriage return does not survive into the version")
    func handlesCarriageReturns() {
        #expect(PromotionFile.stableVersion(in: "stableVersion: 3.32.0\r\nhost: x") == "3.32.0")
    }
}
