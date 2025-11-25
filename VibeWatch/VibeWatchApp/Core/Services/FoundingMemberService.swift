import Foundation

@MainActor
final class FoundingMemberService: ObservableObject {
    static let shared = FoundingMemberService()

    struct PromoStatus {
        let isPromoActive: Bool
        let timeRemaining: TimeInterval
    }

    private let calendar = Calendar.current
    private let promoEndDate: Date

    @Published private(set) var promoStatus: PromoStatus

    private init() {
        // Set the promo end date to November 25, 2025, at midnight
        let launchDate = DateComponents(calendar: .current, year: 2025, month: 10, day: 27).date!
        self.promoEndDate = launchDate.addingTimeInterval(30 * 24 * 60 * 60) // 30 days
        
        self.promoStatus = PromoStatus(isPromoActive: false, timeRemaining: 0)
        refreshPromoStatus()
    }

    func computePromoStatus(now: Date = Date()) -> PromoStatus {
        let timeRemaining = promoEndDate.timeIntervalSince(now)
        let isActive = timeRemaining > 0
        return PromoStatus(isPromoActive: isActive, timeRemaining: max(0, timeRemaining))
    }

    func refreshPromoStatus(now: Date = Date()) {
        promoStatus = computePromoStatus(now: now)
    }

    func getCurrentOffering() -> String {
        return promoStatus.isPromoActive ? "founding_member" : "default"
    }

    func getCountdownText() -> String {
        guard promoStatus.isPromoActive else { return "Promo ended" }

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
    }

    func markAsFoundingMember(productId: String, userId: String?) {
        // TODO: Persist to Supabase once webhook task (2.4) is implemented.
        print("✨ [FoundingMember] Marked user \(userId ?? "anonymous") via product \(productId)")
    }
}
