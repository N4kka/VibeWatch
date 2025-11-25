import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var localizationManager = LocalizationManager.shared
    
    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.theme.textPrimary)
                    }
                    
                    Spacer()
                    
                    Text("settings.title".localized)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                    
                    Spacer()
                    
                    // Invisible button for balance
                    Button {} label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.clear)
                    }
                    .disabled(true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                ScrollView {
                    VStack(spacing: 16) {
                        // Settings content will be added here
                        // Country and Language are now auto-detected from device
                        // and can be changed via the language selector in ProfileView toolbar
                        
                        developerSection
                        
                        Text("More settings coming soon...")
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.top, 40)
                    }
                    .padding(20)
                }
            }
        }
        .navigationBarHidden(true)
    }
    
    private var developerSection: some View {
        VStack(alignment: .leading) {
            Text("Developer")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.theme.textPrimary)
                .padding(.bottom, 10)
            
            Button {
                Task {
                    await forceLogout()
                }
            } label: {
                Text("Force Logout & Reset")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func forceLogout() async {
        do {
            try await AuthService.shared.signOut(force: true)
            appState.isAuthenticated = false
            appState.currentUser = nil
            dismiss()
        } catch {
            print("Error forcing logout: \(error.localizedDescription)")
        }
    }
}

struct SettingItemView: View {
    let icon: String
    let title: String
    let value: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.theme.accentOrange.opacity(0.2))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(.theme.accentOrange)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                    
                    Text(value)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct CountrySelectorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var localizationManager = LocalizationManager.shared
    @State private var searchText = ""
    
    private var filteredCountries: [Country] {
        if searchText.isEmpty {
            return Country.all
        }
        return Country.all.filter { country in
            country.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("settings.selectCountry".localized)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                    
                    Spacer()
                    
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
                .padding(20)
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.theme.textSecondary)
                    
                    TextField("common.search".localized, text: $searchText)
                        .foregroundColor(.theme.textPrimary)
                }
                .padding(12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                // Countries List
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredCountries) { country in
                            Button {
                                localizationManager.setCountry(country)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Text(country.flag)
                                        .font(.system(size: 32))
                                    
                                    Text(country.name)
                                        .font(.system(size: 16))
                                        .foregroundColor(.theme.textPrimary)
                                    
                                    Spacer()
                                    
                                    if country.id == localizationManager.currentCountry.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.theme.accentOrange)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                            }
                            
                            if country.id != filteredCountries.last?.id {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                                    .padding(.leading, 72)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }
}

struct LanguageSelectorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var localizationManager = LocalizationManager.shared
    
    private var availableLanguages: [Language] {
        Language.availableFor(country: localizationManager.currentCountry)
    }
    
    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("settings.selectLanguage".localized)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                    
                    Spacer()
                    
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.theme.textSecondary)
                    }
                }
                .padding(20)
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Languages List
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(availableLanguages) { language in
                            Button {
                                localizationManager.setLanguage(language)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Text(language.nativeName)
                                        .font(.system(size: 16))
                                        .foregroundColor(.theme.textPrimary)
                                    
                                    if language.id != localizationManager.currentCountry.nativeLanguageCode {
                                        Text("(\(language.name))")
                                            .font(.system(size: 14))
                                            .foregroundColor(.theme.textSecondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if language.id == localizationManager.currentLanguage.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.theme.accentOrange)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                            }
                            
                            if language.id != availableLanguages.last?.id {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                                    .padding(.horizontal, 20)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
                
                Spacer()
            }
        }
    }
}

#Preview {
    SettingsView()
}
