import Foundation

/// Pure, side-effect-free display formatters extracted from `ClipsView`.
///
/// `shortTimeAgo` was duplicated verbatim in both `CommentRow` and `ReplyRow`;
/// `shortCount` lived inside `ClipActionButton`. Moving them here removes the
/// duplication and lets the formatting be unit-tested in isolation (Fase 5
/// file-splitting, same approach as `ListItemFilterer` / `DiscoveryRanking`).
/// Behavior is preserved exactly; `shortTimeAgo` takes an injectable reference
/// instant (`now`) so it is deterministic under test.
enum ClipFormatters {

    /// Compact count, e.g. `999` → "999", `1_500` → "1.5K", `2_000_000` → "2.0M".
    static func shortCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    /// Short relative time, e.g. "3w", "2d", "5h", "10m", "30s", or "now".
    /// Only the largest non-zero unit is shown; future/equal dates yield "now".
    static func shortTimeAgo(from date: Date, to now: Date = Date()) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.second, .minute, .hour, .day, .weekOfYear], from: date, to: now)

        if let weeks = components.weekOfYear, weeks > 0 {
            return "\(weeks)w"
        } else if let days = components.day, days > 0 {
            return "\(days)d"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m"
        } else if let seconds = components.second, seconds > 0 {
            return "\(seconds)s"
        } else {
            return "now"
        }
    }
}
