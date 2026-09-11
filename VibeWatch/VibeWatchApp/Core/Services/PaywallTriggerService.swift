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
        let dailyPro = DailyQuotaManager.shared.isProUser
        let clipPro = ClipQuotaService.shared.isProUser

        // ARCH-002 instrumentation. Pro state lives in two independent copies: DailyQuotaManager
        // (UserDefaults-backed cache) and ClipQuotaService (the one derived from RevenueCat). The
        // `||` below deliberately resolves any disagreement in the user's favour, which masks
        // divergence. Before committing to an EntitlementStore refactor, measure whether they ever
        // actually diverge in the field. If this never fires across a release, ARCH-002 is LOW and
        // the refactor isn't worth it; if it fires, this is the evidence — and which side is stale.
        if dailyPro != clipPro {
            Logger.warning("[Entitlement] Pro-state divergence: DailyQuotaManager=\(dailyPro) "
                           + "ClipQuotaService=\(clipPro) — resolving as Pro (permissive)")
        }

        if dailyPro || clipPro {
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
        AnalyticsService.shared.track(.paywallAutoTriggered(source: source))
        NotificationCenter.default.post(name: .presentProPaywall, object: nil, userInfo: ["source": source])
    }
}
