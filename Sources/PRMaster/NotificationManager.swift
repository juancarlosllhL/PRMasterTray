import AppKit
import Observation
import PRMasterCore
import UserNotifications

/// Whether notifications can actually be delivered.
///
/// Surfaced in the UI because a silently denied permission would disable the
/// app's headline feature with no indication anything was wrong.
@MainActor
@Observable
final class NotificationStatus {
    static let shared = NotificationStatus()
    var isDenied = false
    private init() {}
}

/// Posts "ready to merge" notifications and routes their button taps.
final class NotificationManager: NSObject, ReadyPRNotifying, @unchecked Sendable {

    static let shared = NotificationManager()

    typealias OpenHandler = @MainActor (URL) -> Void
    typealias MergeHandler = @MainActor (_ id: String, _ oid: String, _ title: String, _ url: URL) -> Void

    private let lock = NSLock()
    private var onOpen: OpenHandler?
    private var onMerge: MergeHandler?

    private override init() { super.init() }

    /// Must complete before `applicationDidFinishLaunching` returns: a
    /// category registered later than the first delivery means the Open and
    /// Merge buttons simply never appear.
    func register(onOpen: @escaping OpenHandler, onMerge: @escaping MergeHandler) {
        lock.withLock {
            self.onOpen = onOpen
            self.onMerge = onMerge
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        var actions = [
            UNNotificationAction(
                identifier: NotificationRouter.openAction,
                title: "Open PR",
                options: [.foreground]
            )
        ]
        // No Merge button while a debug override is active — the notification
        // would be describing a PR the app cannot safely act on.
        if !Debug.overridesActive {
            actions.append(
                UNNotificationAction(
                    identifier: NotificationRouter.mergeAction,
                    title: "Merge",
                    options: [.foreground]
                )
            )
        }

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: NotificationRouter.categoryID,
                actions: actions,
                intentIdentifiers: [],
                options: []
            )
        ])

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in NotificationStatus.shared.isDenied = !granted }
        }
    }

    /// Re-reads the live permission state.
    ///
    /// Authorization was previously sampled only once at launch, so revoking it
    /// mid-session left the app believing it could still notify — and, with the
    /// post failure swallowed, silently unable to.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let denied = settings.authorizationStatus != .authorized
            && settings.authorizationStatus != .provisional
        await MainActor.run { NotificationStatus.shared.isDenied = denied }
    }

    // MARK: - ReadyPRNotifying

    /// - Throws: whatever `UNUserNotificationCenter` reports. The store relies
    ///   on this to leave the PR unrecorded so delivery is retried; swallowing
    ///   it used to mean the PR was never notified about again.
    func notifyReady(_ pr: PullRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Ready to merge"
        content.subtitle = "\(pr.repo) #\(pr.number)"
        content.body = pr.displayTitle
        content.categoryIdentifier = NotificationRouter.categoryID
        content.userInfo = NotificationRouter.payload(for: pr)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: pr.id, content: content, trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Show the banner even when PRMaster is frontmost — as an accessory app
    /// it has no windows, so suppressing it would mean showing nothing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Delegate callbacks arrive off the main actor, so hop before touching
    /// any UI.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let intent = NotificationRouter.intent(
            action: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo,
            defaultActionIdentifier: UNNotificationDefaultActionIdentifier
        )
        guard let intent else { return }

        let handlers = lock.withLock { (open: onOpen, merge: onMerge) }
        await MainActor.run {
            switch intent {
            case .open(let url):
                handlers.open?(url)
            case .merge(let id, let oid, let title, let url):
                handlers.merge?(id, oid, title, url)
            }
        }
    }
}
