import Foundation

@MainActor
final class PaywallTriggerService {
    static let shared = PaywallTriggerService()

    private enum Keys {
        static let lastAutoPaywallShownAt = "paywall.lastAutoShownAt"
        static let savedToListNudgeShown = "paywall.nudge.savedToListShown"
    }

    private init() {}

    /// High-intent moment: user successfully saved something to a list.
    /// Shows Pro paywall at most once (initial heuristic) and respects cooldowns.
    func recordSavedToList() {
        guard shouldConsiderAutoPaywall() else { return }
        guard !UserDefaults.standard.bool(forKey: Keys.savedToListNudgeShown) else { return }

        UserDefaults.standard.set(true, forKey: Keys.savedToListNudgeShown)
        showProPaywall(source: "saved_to_list")
    }

    // MARK: - Private

    private func shouldConsiderAutoPaywall() -> Bool {
        if DailyQuotaManager.shared.isProUser || ClipQuotaService.shared.isProUser {
            return false
        }

        // Avoid auto paywall for anonymous users; keep their flow focused on account creation first.
        if !AuthService.shared.isAuthenticated {
            return false
        }

        if let last = UserDefaults.standard.object(forKey: Keys.lastAutoPaywallShownAt) as? Date {
            if Date().timeIntervalSince(last) < 24 * 60 * 60 {
                return false
            }
        }

        return true
    }

    private func showProPaywall(source: String) {
        UserDefaults.standard.set(Date(), forKey: Keys.lastAutoPaywallShownAt)
        AnalyticsService.shared.logEvent("paywall_auto_triggered", parameters: [
            "source": source
        ])
        NotificationCenter.default.post(name: .presentProPaywall, object: nil, userInfo: ["source": source])
    }
}
