import SwiftUI
import Combine

/// Redesign 2.0 — il flusso in 5 tappe del prototipo: benvenuto, account, import da TV Time,
/// notifiche, "tutto pronto". Il paywall non è una tappa: appare DOPO "Inizia a guardare",
/// e solo se RevenueCat dice che l'utente non è già PRO (login con account PRO → niente popup).
@MainActor
class OnboardingViewModel: ObservableObject {
    @Published var currentStep: OnboardingStep = .welcome
    @Published var showOnboarding = true
    /// Il paywall a valle di "Inizia a guardare". Alla chiusura (skip o acquisto)
    /// l'onboarding si completa comunque.
    @Published var showPaywall = false
    /// Verifica PRO in corso: il bottone "Inizia a guardare" mostra lo spinner.
    @Published var isCheckingProStatus = false
    /// L'utente ha concesso il permesso notifiche durante il flusso: la chip "Notifiche
    /// attive" della schermata finale la mostra solo chi l'ha davvero attivata.
    @Published var notificationsGranted = false

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case account = 1
        case importHistory = 2
        case notifications = 3
        case ready = 4
    }

    func nextStep() {
        withAnimation(.easeInOut(duration: 0.4)) {
            if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                currentStep = next
                trackStepViewed(step: next)
            }
        }
    }

    func skipStep() {
        trackStepSkipped(step: currentStep)
        nextStep()
    }

    /// "Inizia a guardare": il paywall appare SOLO se l'utente non è già PRO — un login con
    /// un account PRO deve entrare diretto. La verifica passa da RevenueCat (con cache
    /// offline dentro ClipQuotaService), quindi va aspettata, non letta al volo.
    func finish() async {
        guard !isCheckingProStatus else { return }
        isCheckingProStatus = true
        let isPro = await ClipQuotaService.shared.checkIsProUser()
        isCheckingProStatus = false
        if isPro {
            completeOnboarding()
        } else {
            showPaywall = true
        }
    }

    /// All'acquisto dal paywall arrivano sia `onPurchased` sia l'`onDismiss` della cover:
    /// la seconda chiamata non deve rifare niente (né loggare due volte l'evento).
    private var hasCompleted = false

    func completeOnboarding() {
        guard !hasCompleted else { return }
        hasCompleted = true
        Logger.info("[Onboarding] Completing onboarding flow...")
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")

        // Slight delay to allow animation to complete if needed
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation { self.showOnboarding = false }
        }
        AnalyticsService.shared.logEvent("onboarding_complete")
    }

    // Analytics
    func trackStepViewed(step: OnboardingStep) {
        AnalyticsService.shared.logEvent("onboarding_step_viewed", parameters: ["step": stepName(step)])
    }

    func trackStepSkipped(step: OnboardingStep) {
        AnalyticsService.shared.logEvent("onboarding_skipped", parameters: ["step": stepName(step)])
    }

    private func stepName(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "welcome"
        case .account: return "account"
        case .importHistory: return "import"
        case .notifications: return "notifications"
        case .ready: return "ready"
        }
    }
}
