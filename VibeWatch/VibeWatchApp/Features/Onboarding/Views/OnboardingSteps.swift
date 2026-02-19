import SwiftUI

// MARK: - Welcome View
struct OnboardingWelcomeView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Hero Icon/Image
            ZStack {
                Circle()
                    .fill(Color.theme.accentOrange.opacity(0.15))
                    .frame(width: 240, height: 240)
                    .blur(radius: 20)
                
                Image(systemName: "sparkles")
                    .font(.system(size: 100))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.theme.accentOrange, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.bottom, 40)
            
            // Text Content
            VStack(spacing: 16) {
                Text("onboarding.welcome.title".localized) // "Discover Your Vibe"
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
                
                Text("onboarding.welcome.subtitle".localized) // "AI-powered recommendations tailored just for you."
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .lineSpacing(4)
            }
            
            Spacer()
            
            // Action
            PrimaryButton(title: "common.next".localized) {
                viewModel.nextStep()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Clips View
struct OnboardingClipsView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Hero Icon
            ZStack {
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color.theme.accentOrange.opacity(0.15))
                    .frame(width: 200, height: 320)
                    .rotationEffect(.degrees(-6))
                
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 200, height: 320)
                    .overlay(
                        RoundedRectangle(cornerRadius: 30)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .rotationEffect(.degrees(6))
                
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white)
                    .shadow(radius: 10)
            }
            .padding(.bottom, 50)
            
            // Text Content
            VStack(spacing: 16) {
                Text("onboarding.clips.title".localized) // "Watch, Don't Read"
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
                
                Text("onboarding.clips.subtitle".localized) // "Experience movies through short, engaging clips."
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            // Action
            PrimaryButton(title: "common.next".localized) {
                viewModel.nextStep()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Lists View
struct OnboardingListsView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Hero Icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 220, height: 220)
                    .blur(radius: 20)
                
                Image(systemName: "list.bullet.rectangle.portrait.fill")
                    .font(.system(size: 90))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.bottom, 40)
            
            // Text Content
            VStack(spacing: 16) {
                Text("onboarding.lists.title".localized) // "Your Watchlist, Everywhere"
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.theme.textPrimary)
                    .multilineTextAlignment(.center)
                
                Text("onboarding.lists.subtitle".localized) // "Save movies and sync across all your devices."
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            // Action
            PrimaryButton(title: "common.next".localized) {
                viewModel.nextStep()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Shared Components

struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.theme.accentOrange)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color.theme.accentOrange.opacity(0.3), radius: 10, x: 0, y: 5)
        }
    }
}
