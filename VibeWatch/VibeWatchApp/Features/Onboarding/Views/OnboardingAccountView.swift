import SwiftUI

struct OnboardingAccountView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var showSignUp = false
    @State private var showSignIn = false
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Hero Icon
            ZStack {
                Circle()
                    .fill(Color.theme.accentOrange.opacity(0.1))
                    .frame(width: 180, height: 180)
                
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 80))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 30)
            
            // Text Content
            VStack(spacing: 16) {
                Text("onboarding.account.title".localized) // "Save Your Profile"
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
                
                Text("onboarding.account.subtitle".localized) // "Create an account to sync your watchlist and preferences across devices."
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            // Actions
            VStack(spacing: 16) {
                // Create Account Button
                Button {
                    showSignUp = true
                } label: {
                    Text("auth.createAccount".localized)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.theme.accentOrange)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                
                // Sign In Button (Secondary)
                Button {
                    showSignIn = true
                } label: {
                    Text("auth.signIn".localized)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.theme.textSecondary)
                }
                
                // Skip Button (Tertiary)
                Button {
                    viewModel.skipToPaywall()
                } label: {
                    Text("onboarding.skip".localized)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.theme.textSecondary.opacity(0.7))
                        .underline()
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
                .environmentObject(appState)
                .environmentObject(authService)
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
                .environmentObject(appState)
                .environmentObject(authService)
        }
    }
}
