import Foundation

/// Encapsulates the math behind the logged-in clip quota rules so it can be reused and tested.
struct DailyClipQuotaLogic {
    let limit: Int
    let calendar: Calendar
    let nowProvider: () -> Date
    
    init(limit: Int, calendar: Calendar = .current, nowProvider: @escaping () -> Date = { Date() }) {
        self.limit = limit
        self.calendar = calendar
        self.nowProvider = nowProvider
    }
    
    /// Returns true when a new day has begun and the counter should reset.
    func shouldReset(lastResetAt: Date?) -> Bool {
        guard let lastResetAt else { return true }
        return !calendar.isDate(lastResetAt, inSameDayAs: nowProvider())
    }
    
    /// Attempts to increment the quota counter while respecting the daily limit.
    func incrementedCount(from current: Int) -> IncrementResult {
        guard current < limit else {
            return IncrementResult(updatedCount: current, didIncrement: false)
        }
        let newCount = min(current + 1, limit)
        return IncrementResult(updatedCount: newCount, didIncrement: true)
    }
    
    struct IncrementResult {
        let updatedCount: Int
        let didIncrement: Bool
    }
}
