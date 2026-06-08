import Foundation

/// Pure formatting/parsing helpers used by Supabase sync and quota flows.
enum SupabaseSyncFormatting {

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func localDayKey(for date: Date = Date()) -> String {
        dayKeyFormatter.string(from: date)
    }

    static func isDateInTodayLocal(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }

    static func normalizeUserId(_ userId: String) -> String {
        userId.lowercased()
    }

    static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }
}
