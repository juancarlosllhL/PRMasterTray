import Foundation
import Testing
@testable import PRMasterCore

private func promoted(
    _ environment: DeployEnvironment,
    _ region: String,
    _ version: String
) -> PromotedVersion {
    PromotedVersion(
        file: PromotionFile(environment: environment, region: region),
        version: version
    )
}

@Suite("Environment promotion")
struct PromotionTests {

    // MARK: the ordinary case

    @Test("two regions holding the same version collapse to one")
    func regionsAgreeing() throws {
        let collapsed = EnvironmentPromotion.collapse([
            promoted(.staging, "euw1", "3.32.0"),
            promoted(.staging, "use2", "3.32.0"),
        ])

        let staging = try #require(collapsed.first)
        #expect(staging.versions == ["3.32.0"])
        #expect(staging.regionsAgree)
        #expect(staging.displayVersion == "3.32.0")
    }

    @Test("a single region agrees with itself")
    func singleRegion() throws {
        let collapsed = EnvironmentPromotion.collapse([promoted(.production, "euw1", "3.31.1")])
        let production = try #require(collapsed.first)
        #expect(production.regionsAgree)
        #expect(production.displayVersion == "3.31.1")
    }

    // MARK: a rollout still in flight

    /// The lower version is what gets shown, because a rollout that has reached
    /// one region has not reached the environment.
    @Test("diverging regions report the lower version and say so")
    func regionsDiverging() throws {
        let collapsed = EnvironmentPromotion.collapse([
            promoted(.staging, "euw1", "3.32.0"),
            promoted(.staging, "use2", "3.31.1"),
        ])

        let staging = try #require(collapsed.first)
        #expect(staging.regionsAgree == false)
        #expect(staging.displayVersion == "3.31.1")
    }

    /// Compared component-wise as integers. Sorted as strings, `"1.10.0"` lands
    /// below `"1.9.0"` and the app would name a version the environment had
    /// already moved past — the first bump where a string compare goes wrong.
    @Test("the lower version is decided numerically, not lexicographically")
    func lowerVersionIsNumeric() throws {
        let collapsed = EnvironmentPromotion.collapse([
            promoted(.production, "euw1", "1.10.0"),
            promoted(.production, "use2", "1.9.0"),
        ])
        #expect(try #require(collapsed.first).displayVersion == "1.9.0")
    }

    /// Every region's version is kept, not just the one shown. Whether a change
    /// reached an environment is answered per region by containment later; if
    /// this list collapsed to the display pick, that decision would silently
    /// inherit an ordering it must never depend on.
    @Test("every region's version survives collapsing")
    func keepsEveryRegionVersion() throws {
        let collapsed = EnvironmentPromotion.collapse([
            promoted(.staging, "euw1", "3.32.0"),
            promoted(.staging, "use2", "3.31.1"),
        ])
        #expect(Set(try #require(collapsed.first).versions) == ["3.32.0", "3.31.1"])
    }

    @Test("identical versions across regions are not repeated")
    func deduplicates() throws {
        let collapsed = EnvironmentPromotion.collapse([
            promoted(.staging, "euw1", "3.32.0"),
            promoted(.staging, "use2", "3.32.0"),
            promoted(.staging, "usw1", "3.32.0"),
        ])
        #expect(try #require(collapsed.first).versions == ["3.32.0"])
    }

    // MARK: what is absent

    /// An environment nobody has promoted to is left out entirely. Present but
    /// empty would render as a chip with nothing in it.
    @Test("an environment with no promotion is absent, not empty")
    func absentEnvironment() {
        let collapsed = EnvironmentPromotion.collapse([promoted(.staging, "euw1", "3.32.0")])
        #expect(collapsed.count == 1)
        #expect(collapsed.contains { $0.environment == .production } == false)
    }

    @Test("nothing promoted yields nothing at all")
    func nothingPromoted() {
        #expect(EnvironmentPromotion.collapse([]).isEmpty)
    }

    // MARK: order

    /// Staging first, so a row reads in the order a change actually travels.
    @Test("staging is reported before production regardless of input order")
    func stagingComesFirst() {
        let collapsed = EnvironmentPromotion.collapse([
            promoted(.production, "euw1", "3.31.1"),
            promoted(.staging, "euw1", "3.32.0"),
        ])
        #expect(collapsed.map(\.environment) == [.staging, .production])
    }
}
