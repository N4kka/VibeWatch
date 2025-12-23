import SwiftUI

struct OnboardingPaywallWrapper: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var isPresented = true // Binding dummy
    
    var body: some View {
        ProPaywallView(
            isPresented: $isPresented,
            source: "onboarding",
            isOnboarding: true,
            onPurchased: {
                // On successful purchase, complete onboarding
                viewModel.completeOnboarding()
            }
        )
        // Observe if isPresented becomes false (user tapped Skip)
        .onChange(of: isPresented) { _, newValue in
            if !newValue {
                viewModel.skipToCompletion()
            }
        }
    }
}
