import SwiftUI

/// Redesign 2.0 — il contenitore delle 5 tappe. Tiene lui l'ImportViewModel (l'import parte
/// alla tappa 3 ma i numeri servono ancora alla schermata finale) e presenta il paywall come
/// cover a valle di "Inizia a guardare" — mai come tappa, e mai per chi è già PRO.
struct OnboardingContainerView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    /// Redesign 2.0: l'oblò dell'import è quello CONDIVISO di tutta l'app. Se l'utente
    /// prosegue l'onboarding con l'import in corso, il polling non muore con questa vista —
    /// il banner in Scopri continua a raccontarlo.
    @ObservedObject private var importViewModel = ImportStatusCenter.shared.importViewModel
    @EnvironmentObject var authService: AuthService
    @Binding var showOnboarding: Bool

    var body: some View {
        ZStack {
            // Background: nero del tema con un alone appena percettibile al centro,
            // come nel prototipo.
            Color.theme.background.ignoresSafeArea()
            RadialGradient(colors: [Color.white.opacity(0.04), .clear],
                           center: .center, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                OnboardingProgressIndicator(currentStep: viewModel.currentStep)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)

                Group {
                    switch viewModel.currentStep {
                    case .welcome:
                        OnboardingWelcomeStep(viewModel: viewModel)
                    case .account:
                        OnboardingAccountStep(viewModel: viewModel)
                            .onAppear {
                                if authService.isAuthenticated {
                                    Logger.info("[Onboarding] User already authenticated, skipping Account step")
                                    viewModel.nextStep()
                                }
                            }
                    case .importHistory:
                        OnboardingImportStep(viewModel: viewModel,
                                             importViewModel: importViewModel)
                    case .notifications:
                        OnboardingNotificationsStep(viewModel: viewModel)
                    case .ready:
                        OnboardingReadyStep(viewModel: viewModel,
                                            importViewModel: importViewModel)
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        // Il paywall di chiusura: alla dismiss — skip in alto a destra o acquisto —
        // l'onboarding è comunque finito.
        .fullScreenCover(isPresented: $viewModel.showPaywall,
                         onDismiss: { viewModel.completeOnboarding() }) {
            ProPaywallView(
                isPresented: $viewModel.showPaywall,
                source: "onboarding",
                isOnboarding: true,
                onPurchased: { viewModel.completeOnboarding() }
            )
        }
        .onChange(of: viewModel.showOnboarding) { _, newValue in
            showOnboarding = newValue
        }
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated && viewModel.currentStep == .account {
                Logger.info("[Onboarding] User authenticated, moving to Import step")
                viewModel.nextStep()
            }
        }
        .onAppear {
            viewModel.trackStarted()
        }
        // Niente stopPolling alla dismiss: il ViewModel è condiviso e il polling deve
        // sopravvivere all'onboarding — è ciò che alimenta il banner in home. Si spegne da
        // solo quando il job esce da `running`.
    }
}

/// I 5 segmenti in alto a sinistra del prototipo: la tappa corrente è una capsula larga,
/// le passate punti arancioni, le future punti spenti.
struct OnboardingProgressIndicator: View {
    let currentStep: OnboardingViewModel.OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingViewModel.OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= currentStep.rawValue
                          ? Color.theme.accentOrange
                          : Color.white.opacity(0.18))
                    .frame(width: step == currentStep ? 34 : 7, height: 7)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.3), value: currentStep)
    }
}
