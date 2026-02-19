import SwiftUI
import Combine

@MainActor
class OnboardingViewModel: ObservableObject {
    @Published var currentStep: OnboardingStep = .welcome
    @Published var showOnboarding = true
    @Published var isSignUpPresented = false
    
    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case clips = 1
        case lists = 2
        case account = 3
        case paywall = 4
    }
    
    func nextStep() {
        withAnimation(.easeInOut(duration: 0.4)) {
            if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                currentStep = next
                trackStepViewed(step: next)
            } else {
                completeOnboarding()
            }
        }
    }
    
    func skipToPaywall() {
        withAnimation {
            currentStep = .paywall
            trackStepSkipped(step: .account)
        }
    }
    
    func skipToCompletion() {
        trackStepSkipped(step: currentStep)
        completeOnboarding()
    }
    
    func completeOnboarding() {
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
        case .clips: return "clips"
        case .lists: return "lists"
        case .account: return "account"
        case .paywall: return "paywall"
        }
    }
}
