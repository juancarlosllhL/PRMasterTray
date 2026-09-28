import Foundation
import Testing
@testable import PRMasterCore

private final class FakeWindow {}

@MainActor
@Suite("Diff windows")
struct DiffWindowTests {

    @Test("reviewing the same pull request again brings back its window")
    func sameKeyReuses() {
        let registry = WindowRegistry<FakeWindow>()
        let first = registry.window(for: "PR_1") { FakeWindow() }
        let second = registry.window(for: "PR_1") { FakeWindow() }
        #expect(first.isNew)
        #expect(!second.isNew)
        #expect(first.window === second.window)
        #expect(registry.count == 1)
    }

    @Test("each pull request gets its own window")
    func differentKeys() {
        let registry = WindowRegistry<FakeWindow>()
        let first = registry.window(for: "PR_1") { FakeWindow() }
        let second = registry.window(for: "PR_2") { FakeWindow() }
        #expect(first.window !== second.window)
        #expect(registry.count == 2)
    }

    @Test("a closed window is forgotten, so reviewing again opens a fresh one")
    func closedIsForgotten() {
        let registry = WindowRegistry<FakeWindow>()
        let first = registry.window(for: "PR_1") { FakeWindow() }
        registry.remove("PR_1")
        let second = registry.window(for: "PR_1") { FakeWindow() }
        #expect(registry.count == 1)
        #expect(second.isNew)
        #expect(first.window !== second.window)
    }

    @Test("a current, complete diff needs no banner")
    func noBanner() {
        #expect(DiffBanner.banner(for: .loaded, isTruncated: false) == nil)
        #expect(DiffBanner.banner(for: .loading, isTruncated: false) == nil)
    }

    @Test(
        "every state that blocks merging says why, in its own words",
        arguments: [
            (DiffStore.Phase.headMoved, false),
            (.closed, false),
            (.loaded, true),
            (.failed("GitHub is having trouble (HTTP 502). Try again in a moment."), false),
        ]
    )
    func blockingStatesExplain(phase: DiffStore.Phase, truncated: Bool) throws {
        let banner = try #require(DiffBanner.banner(for: phase, isTruncated: truncated))
        #expect(!banner.message.isEmpty)
    }

    @Test("the four blocking states never share a message")
    func messagesAreDistinct() {
        let messages = [
            DiffBanner.banner(for: .headMoved, isTruncated: false),
            DiffBanner.banner(for: .closed, isTruncated: false),
            DiffBanner.banner(for: .loaded, isTruncated: true),
            DiffBanner.banner(for: .failed("x"), isTruncated: false),
        ].compactMap { $0?.message }
        #expect(Set(messages).count == 4)
    }

    @Test("new commits offer a reload, a failure a retry, and a failure keeps GitHub's words")
    func actions() {
        #expect(DiffBanner.banner(for: .headMoved, isTruncated: false)?.actions == [.reload])
        let failed = DiffBanner.banner(for: .failed("Bad credentials"), isTruncated: false)
        #expect(failed?.actions == [.retry, .openOnGitHub])
        #expect(failed?.message == "Bad credentials")
        #expect(DiffBanner.banner(for: .loaded, isTruncated: true)?.actions == [.openOnGitHub])
    }

    @Test("new commits outrank truncation, since reloading is the next step either way")
    func headMovedOutranksTruncation() {
        #expect(DiffBanner.banner(for: .headMoved, isTruncated: true)?.actions == [.reload])
    }
}
