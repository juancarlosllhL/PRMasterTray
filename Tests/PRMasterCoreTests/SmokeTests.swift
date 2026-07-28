import Testing
@testable import PRMasterCore

/// Establishes that the test target builds and Swift Testing is wired up, so
/// later stories start from a known-green baseline. Real behavioural tests
/// arrive with `Readiness` in story 002.
@Test func coreTargetIsImportable() {
    #expect(PRMasterCore.version == "0.1.0")
}
