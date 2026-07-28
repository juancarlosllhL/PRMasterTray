import Foundation

/// What the user asked for by tapping a notification or one of its buttons.
public enum NotificationIntent: Equatable, Sendable {
    case open(URL)
    case merge(id: String, oid: String, title: String, url: URL)
}

/// Translates a notification response into an intent.
///
/// Kept as a pure mapping so the routing can be tested without standing up
/// UNUserNotificationCenter, which needs a signed bundle and a running app.
public enum NotificationRouter {

    public static let categoryID = "PR_READY"
    public static let openAction = "OPEN"
    public static let mergeAction = "MERGE"

    enum Key {
        static let url = "url"
        static let id = "id"
        static let oid = "oid"
        static let title = "title"
    }

    /// The payload carried on the notification, so acting on it needs no
    /// lookup against a list that may have changed since it was posted.
    public static func payload(for pr: PullRequest) -> [String: String] {
        [
            Key.url: pr.url.absoluteString,
            Key.id: pr.id,
            // Pinned at post time: merging must use the commit the user was
            // told about, not whatever is newest when they click.
            Key.oid: pr.headRefOid,
            // Only ever shown to a human — it becomes the merge dialog's
            // informative text — so it carries the rendered form.
            Key.title: pr.displayTitle,
        ]
    }

    /// - Returns: `nil` for dismissals and anything unrecognised, so an
    ///   unfamiliar identifier can never fall through into a merge.
    public static func intent(
        action: String,
        userInfo: [AnyHashable: Any],
        defaultActionIdentifier: String
    ) -> NotificationIntent? {
        func string(_ key: String) -> String? { userInfo[key] as? String }

        switch action {
        case openAction, defaultActionIdentifier:
            guard let raw = string(Key.url), let url = URL(string: raw) else { return nil }
            return .open(url)

        case mergeAction:
            guard let id = string(Key.id),
                  let oid = string(Key.oid),
                  let title = string(Key.title),
                  let raw = string(Key.url), let url = URL(string: raw),
                  !id.isEmpty, !oid.isEmpty else { return nil }
            return .merge(id: id, oid: oid, title: title, url: url)

        default:
            return nil
        }
    }
}
