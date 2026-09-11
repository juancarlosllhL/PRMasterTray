import Foundation

/// How long ago something happened, in words.
///
/// Hand-rolled for the same reasons as `StaleAge`: the boundaries are
/// table-tested rather than eyeballed, and it allocates nothing per row.
public enum RelativeAge {

    public static func label(since moment: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(moment))
        if seconds < 60 { return "just now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return ago(minutes, "minute") }

        let hours = minutes / 60
        if hours < 24 { return ago(hours, "hour") }

        let days = hours / 24
        if days < 30 { return ago(days, "day") }
        if days < 365 { return ago(days / 30, "month") }
        return ago(days / 365, "year")
    }

    private static func ago(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun) ago" : "\(count) \(noun)s ago"
    }
}
