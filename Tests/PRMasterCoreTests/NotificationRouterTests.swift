import Foundation
import Testing
@testable import PRMasterCore

private let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"
private let dismissAction = "com.apple.UNNotificationDismissActionIdentifier"

private func makePR() -> PullRequest {
    PullRequest(
        id: "PR_node123", number: 42, title: "add rate limit headers",
        url: URL(string: "https://github.com/acme/infra/pull/42")!,
        repo: "acme/infra", isPrivate: false, isDraft: false, headRefOid: "abc123",
        mergeable: .mergeable, mergeState: .clean,
        reviewDecision: .approved, checks: .success, approvals: 1,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("NotificationRouter")
struct NotificationRouterTests {

    private func route(_ action: String, _ userInfo: [AnyHashable: Any]) -> NotificationIntent? {
        NotificationRouter.intent(
            action: action, userInfo: userInfo, defaultActionIdentifier: defaultAction
        )
    }

    @Test("the payload carries everything needed to act without a lookup")
    func payloadIsSelfContained() {
        let payload = NotificationRouter.payload(for: makePR())
        #expect(payload["id"] == "PR_node123")
        // Pinned at post time so a merge uses the commit the user was told about.
        #expect(payload["oid"] == "abc123")
        #expect(payload["url"] == "https://github.com/acme/infra/pull/42")
        #expect(payload["title"] == "add rate limit headers")
    }

    /// The payload title becomes the merge dialog's informative text, so it has
    /// to be the rendered form rather than the raw shortcode.
    @Test("the payload carries the rendered title")
    func payloadTitleIsRendered() {
        let pr = PullRequest(
            id: "PR_1", number: 1, title: ":sparkles: add rate limit headers",
            url: URL(string: "https://github.com/acme/infra/pull/42")!,
            repo: "acme/infra", isPrivate: false, isDraft: false, headRefOid: "abc123",
            mergeable: .mergeable, mergeState: .clean,
            reviewDecision: .approved, checks: .success, approvals: 1,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(NotificationRouter.payload(for: pr)["title"] == "✨ add rate limit headers")
    }

    @Test("the Open button opens the PR")
    func openAction() {
        let payload = NotificationRouter.payload(for: makePR())
        #expect(route("OPEN", payload)
            == .open(URL(string: "https://github.com/acme/infra/pull/42")!))
    }

    @Test("tapping the notification body opens the PR")
    func defaultActionOpens() {
        #expect(route(defaultAction, NotificationRouter.payload(for: makePR()))
            == .open(URL(string: "https://github.com/acme/infra/pull/42")!))
    }

    @Test("the Merge button carries the pinned head oid")
    func mergeAction() {
        #expect(route("MERGE", NotificationRouter.payload(for: makePR()))
            == .merge(
                id: "PR_node123", oid: "abc123", title: "add rate limit headers",
                url: URL(string: "https://github.com/acme/infra/pull/42")!
            ))
    }

    /// Anything unrecognised must resolve to nothing rather than falling
    /// through into an irreversible action.
    @Test("unknown and dismiss identifiers do nothing",
          arguments: [dismissAction, "SOMETHING_ELSE", ""])
    func unknownActionsIgnored(action: String) {
        #expect(route(action, NotificationRouter.payload(for: makePR())) == nil)
    }

    @Test("a merge with a missing oid is refused")
    func mergeWithoutOid() {
        var payload = NotificationRouter.payload(for: makePR())
        payload["oid"] = nil
        #expect(route("MERGE", payload) == nil)

        payload["oid"] = ""
        #expect(route("MERGE", payload) == nil, "an empty guard is no guard")
    }

    @Test("a merge with a missing id is refused")
    func mergeWithoutID() {
        var payload = NotificationRouter.payload(for: makePR())
        payload["id"] = nil
        #expect(route("MERGE", payload) == nil)
    }

    @Test("an unparseable url is refused rather than crashing")
    func badURL() {
        #expect(route("OPEN", ["url": ""]) == nil)
        #expect(route("OPEN", [:]) == nil)
    }
}
