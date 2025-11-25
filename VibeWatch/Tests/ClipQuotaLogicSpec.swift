import Foundation

@main
struct ClipQuotaLogicSpec {
    static func main() {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let referenceDate = formatter.date(from: "2024-01-01T12:00:00Z") else {
            fatalError("Unable to create reference date for tests")
        }
        let logic = DailyClipQuotaLogic(limit: 15, calendar: calendar, nowProvider: { referenceDate })
        var count = 0
        for index in 1...15 {
            let result = logic.incrementedCount(from: count)
            assert(result.didIncrement, "Clip \(index) should increment")
            count = result.updatedCount
        }
        let blocked = logic.incrementedCount(from: count)
        assert(!blocked.didIncrement, "16th clip should be blocked")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: referenceDate)!
        let tomorrowLogic = DailyClipQuotaLogic(limit: 15, calendar: calendar, nowProvider: { tomorrow })
        assert(tomorrowLogic.shouldReset(lastResetAt: referenceDate), "Next day should reset the quota")
        print("✅ Clip quota logic spec passed")
    }
}
