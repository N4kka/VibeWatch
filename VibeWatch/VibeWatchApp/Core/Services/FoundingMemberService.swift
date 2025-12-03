import Foundation

@MainActor
final class FoundingMemberService: ObservableObject {
    static let shared = FoundingMemberService()

    struct PromoStatus {
        let isPromoActive: Bool
        let timeRemaining: TimeInterval
    }

    private let calendar = Calendar.current
    let promoStartDate: Date
    let promoEndDate: Date

    @Published private(set) var promoStatus: PromoStatus

    private init() {
        // Configure fixed promo window (e.g., Dec 10 to Jan 10)
        let startMonth = 12
        let startDay = 1
        let endMonth = 1
        let endDay = 1

        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        var startComponents = DateComponents(calendar: calendar, year: currentYear, month: startMonth, day: startDay)
        var endYear = currentYear
        if endMonth < startMonth { endYear += 1 }
        var endComponents = DateComponents(calendar: calendar, year: endYear, month: endMonth, day: endDay)

        var startDate = calendar.date(from: startComponents)!
        var endDate = calendar.date(from: endComponents)!

        // If the window already passed for this cycle, shift to the next one
        if now > endDate {
            startComponents.year = (startComponents.year ?? currentYear) + 1
            endComponents.year = (endComponents.year ?? endYear) + 1
            startDate = calendar.date(from: startComponents)!
            endDate = calendar.date(from: endComponents)!
        }

        self.promoStartDate = startDate
        self.promoEndDate = endDate
        
        self.promoStatus = PromoStatus(isPromoActive: false, timeRemaining: 0)
        refreshPromoStatus()
    }

    func computePromoStatus(now: Date = Date()) -> PromoStatus {
        let isActive = (now >= promoStartDate) && (now <= promoEndDate)
        let timeRemaining = isActive ? promoEndDate.timeIntervalSince(now) : 0
        return PromoStatus(isPromoActive: isActive, timeRemaining: max(0, timeRemaining))
    }

    func refreshPromoStatus(now: Date = Date()) {
        promoStatus = computePromoStatus(now: now)
    }

    func getCurrentOffering() -> String {
        return promoStatus.isPromoActive ? "founding_member" : "default"
    }

    func getCountdownText() -> String {
        let now = Date()

        if promoStatus.isPromoActive {
            let hoursRemaining = Int(ceil(promoStatus.timeRemaining / 3600))
            let daysRemaining = Int(ceil(promoStatus.timeRemaining / (3600 * 24)))

            if hoursRemaining <= 48 {
                if hoursRemaining > 0 {
                    return "\(hoursRemaining) hours left"
                } else {
                    return "Last chance!"
                }
            } else {
                return "\(daysRemaining) days left"
            }
        } else if now < promoStartDate {
            let secondsToStart = promoStartDate.timeIntervalSince(now)
            let hours = Int(ceil(secondsToStart / 3600))
            let days = Int(ceil(secondsToStart / (3600 * 24)))
            if hours <= 48 {
                return "Starts in \(hours)h"
            } else {
                return "Starts in \(days) days"
            }
        } else {
            return "Promo ended"
        }
    }

    func markAsFoundingMember(productId: String, userId: String?) {
        // TODO: Persist to Supabase once webhook task (2.4) is implemented.
        print("✨ [FoundingMember] Marked user \(userId ?? "anonymous") via product \(productId)")
    }
}
