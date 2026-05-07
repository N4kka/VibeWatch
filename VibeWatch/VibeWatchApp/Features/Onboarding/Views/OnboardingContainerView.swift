import SwiftUI

struct OnboardingContainerView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @EnvironmentObject var authService: AuthService
    @Binding var showOnboarding: Bool
    
    var body: some View {
        ZStack {
            // Background
            Color.theme.background.ignoresSafeArea()
            
            // Content
            Group {
                switch viewModel.currentStep {
                case .welcome:
                    OnboardingWelcomeView(viewModel: viewModel)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case .clips:
                    OnboardingClipsView(viewModel: viewModel)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case .lists:
                    OnboardingListsView(viewModel: viewModel)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case .account:
                    OnboardingAccountView(viewModel: viewModel)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                        .onAppear {
                            if authService.isAuthenticated {
                                Logger.info("[Onboarding] User already authenticated, skipping Account step")
                                viewModel.nextStep()
                            }
                        }
                case .paywall:
                    OnboardingPaywallWrapper(viewModel: viewModel)
                        .transition(.opacity)
                }
            }
        }
        .onChange(of: viewModel.showOnboarding) { _, newValue in
            showOnboarding = newValue
        }
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated && viewModel.currentStep == .account {
                Logger.info("[Onboarding] User authenticated, moving to Paywall")
                viewModel.nextStep()
            }
        }
        .onAppear {
            viewModel.trackStepViewed(step: .welcome)
        }
    }
}
