import Foundation

@MainActor
final class LocalGamificationRepository: GamificationRepositoryProtocol {
    static let shared = LocalGamificationRepository(db: .shared)

    private let db: SQLiteService

    init(db: SQLiteService) {
        self.db = db
    }

    func loadState(userId: String) async -> UserGamificationState? {
        let rows = (try? await db.queryRaw(
            "SELECT * FROM user_gamification WHERE user_id = ?",
            parameters: [userId]
        )) ?? []

        guard let row = rows.first else { return nil }
        return Self.state(from: row)
    }

    func saveState(_ state: UserGamificationState, userId: String) async {
        let sql = """
            INSERT INTO user_gamification
            (user_id, total_xp, current_level, current_streak, longest_streak, last_activity_date, streak_freezes_remaining, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(user_id) DO UPDATE SET
                total_xp = excluded.total_xp,
                current_level = excluded.current_level,
                current_streak = excluded.current_streak,
                longest_streak = excluded.longest_streak,
                last_activity_date = excluded.last_activity_date,
                streak_freezes_remaining = excluded.streak_freezes_remaining,
                updated_at = excluded.updated_at
        """
        db.execute(sql, parameters: [
            userId,
            state.totalXP,
            state.currentLevel,
            state.currentStreak,
            state.longestStreak,
            state.lastActivityDate?.ISO8601Format() ?? NSNull(),
            state.streakFreezesRemaining
        ])
    }

    func awardXP(userId: String, action: XPActionType, customXP: Int?, isPro: Bool, source: String?) async throws -> AwardXPResult {
        throw SupabaseError.notConfigured
    }

    static func state(from row: [String: Any]) -> UserGamificationState {
        var state = UserGamificationState()
        state.totalXP = row["total_xp"] as? Int ?? 0
        state.currentLevel = row["current_level"] as? Int ?? 1
        state.currentStreak = row["current_streak"] as? Int ?? 0
        state.longestStreak = row["longest_streak"] as? Int ?? 0
        state.streakFreezesRemaining = row["streak_freezes_remaining"] as? Int ?? 0

        if let dateString = row["last_activity_date"] as? String {
            state.lastActivityDate = parseRemoteDate(dateString)
        }

        return state
    }

    nonisolated static func parseRemoteDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
