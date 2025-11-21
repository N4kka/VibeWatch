import SwiftUI

struct OnboardingView: View {
    @State private var currentPage = 0
    @Binding var showOnboarding: Bool
    
    var body: some View {
        ZStack {
            // Background
            Color.theme.background
                .ignoresSafeArea()
            
            TabView(selection: $currentPage) {
                OnboardingPage1()
                    .tag(0)
                
                OnboardingPage2()
                    .tag(1)
                
                OnboardingPage3()
                    .tag(2)
                
                OnboardingPage4(showOnboarding: $showOnboarding)
                    .tag(3)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Page 1: Track and Save Favorites
struct OnboardingPage1: View {
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Image/Icon
            ZStack {
                Circle()
                    .fill(Color.theme.accentOrange.opacity(0.2))
                    .frame(width: 200, height: 200)
                
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.theme.accentOrange)
            }
            .padding(.bottom, 16)
            
            // Title
            Text("onboarding.page1.title".localized)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            
            // Description
            Text("onboarding.page1.description".localized)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .lineSpacing(4)
            
            Spacer()
        }
    }
}

// MARK: - Page 2: Save to Lists
struct OnboardingPage2: View {
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Image/Icon
            ZStack {
                Circle()
                    .fill(Color.theme.accentOrange.opacity(0.2))
                    .frame(width: 200, height: 200)
                
                Image(systemName: "list.bullet.rectangle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.theme.accentOrange)
            }
            .padding(.bottom, 16)
            
            // Title
            Text("onboarding.page2.title".localized)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            
            // Description
            Text("onboarding.page2.description".localized)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .lineSpacing(4)
            
            Spacer()
        }
    }
}

// MARK: - Page 3: Clips Discovery
struct OnboardingPage3: View {
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Image/Icon
            ZStack {
                Circle()
                    .fill(Color.theme.accentOrange.opacity(0.2))
                    .frame(width: 200, height: 200)
                
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.theme.accentOrange)
            }
            .padding(.bottom, 16)
            
            // Title
            Text("onboarding.page3.title".localized)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            
            // Description
            Text("onboarding.page3.description".localized)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .lineSpacing(4)
            
            Spacer()
        }
    }
}

// MARK: - Page 4: Get Started / Account Creation
struct OnboardingPage4: View {
    @Binding var showOnboarding: Bool
    @State private var showProfileView = false
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Logo or Icon
            Image(systemName: "tv.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.theme.accentOrange)
                .padding(.bottom, 16)
            
            // Title
            Text("onboarding.page4.title".localized)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            
            // Description
            Text("onboarding.page4.description".localized)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .lineSpacing(4)
                .padding(.bottom, 8)
            
            // Language Selector
            OnboardingLanguageSelector()
                .padding(.bottom, 16)
            
            // CTA Buttons
            VStack(spacing: 16) {
                // Create Account Button
                Button {
                    showProfileView = true
                } label: {
                    Text("onboarding.page4.createAccount".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.theme.accentOrange)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 48)
                
                // Skip Button
                Button {
                    skipToDiscovery()
                } label: {
                    Text("onboarding.page4.skip".localized)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.theme.textSecondary)
                }
                .padding(.horizontal, 48)
            }
            
            Spacer()
        }
        .sheet(isPresented: $showProfileView, onDismiss: {
            // When ProfileView is dismissed, complete onboarding
            completeOnboarding()
        }) {
            ProfileView()
        }
    }
    
    private func skipToDiscovery() {
        print("🟢 [Onboarding] Skip button tapped")
        completeOnboarding()
    }
    
    private func completeOnboarding() {
        print("🟢 [Onboarding] Completing onboarding...")
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        print("🟢 [Onboarding] UserDefaults set to true")
        
        // Update binding to hide onboarding and show main app
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                showOnboarding = false
                print("🟢 [Onboarding] showOnboarding set to false (hiding onboarding)")
            }
        }
    }
}

// MARK: - Onboarding Language Selector
struct OnboardingLanguageSelector: View {
    @StateObject private var localizationManager = LocalizationManager.shared
    
    // Map language codes to flag emojis
    private func flagForLanguage(_ languageCode: String) -> String {
        switch languageCode {
            case "en": return "🇺🇸 ".localized
            case "it": return "🇮🇹 ".localized
            case "es": return "🇪🇸 ".localized
            case "fr": return "🇫🇷 ".localized
            case "de": return "🇩🇪 ".localized
            case "ja": return "🇯🇵 ".localized
            case "ko": return "🇰🇷 ".localized
            case "zh": return "🇨🇳 ".localized
            case "pt": return "🇵🇹 ".localized
            case "hi": return "🇮🇳 ".localized
            case "ru": return "🇷🇺 ".localized
            case "nl": return "🇳🇱 ".localized
            case "sv": return "🇸🇪 ".localized
            case "no": return "🇳🇴 ".localized
            case "da": return "🇩🇰 ".localized
            case "fi": return "🇫🇮 ".localized
            case "pl": return "🇵🇱 ".localized
            case "tr": return "🇹🇷 ".localized
            case "el": return "🇬🇷 ".localized
            default: return "🌐".localized
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("settings.language".localized)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.theme.textSecondary)
            
            Menu {
                ForEach(Language.all, id: \.id) { language in
                    Button(action: {
                        localizationManager.setLanguage(language)
                    }) {
                        HStack {
                            Text(flagForLanguage(language.id) + language.nativeName)
                            
                            Spacer()
                            
                            if localizationManager.currentLanguage.id == language.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.theme.accentOrange)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Text(flagForLanguage(localizationManager.currentLanguage.id))
                        .font(.system(size: 24))
                    
                    Text(localizationManager.currentLanguage.nativeName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
