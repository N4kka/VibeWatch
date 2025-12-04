import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @StateObject private var localizationManager = LocalizationManager.shared
    @State private var showDeleteAccountPanel = false
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deletionError: String?
    
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
                        Text("settings.comingSoon".localized)
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.top, 12)
                        
                        VStack(spacing: 0) {
                            Button {
                                deletionError = nil
                                showDeleteAccountPanel = true
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "trash.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.theme.accentOrange)
                                        .frame(width: 30)
                                    
                                    Text("settings.deleteAccount".localized)
                                        .font(.system(size: 16))
                                        .foregroundColor(.theme.textPrimary)
                                        .multilineTextAlignment(.leading)
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14))
                                        .foregroundColor(.theme.textSecondary)
                                }
                                .padding()
                            }
                        }
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 8)
                        
                        if let deletionError {
                            Text(deletionError)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationBarHidden(true)
        .overlay {
            if showDeleteAccountPanel {
                popupOverlayBackground(onTap: { showDeleteAccountPanel = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                deleteAccountPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
            }
        }
        .overlay {
            if showDeleteAccountConfirmation {
                popupOverlayBackground(onTap: { showDeleteAccountConfirmation = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                ConfirmationPopup(
                    title: "settings.deleteAccountFinalTitle".localized,
                    message: "settings.deleteAccountFinalMessage".localized,
                    confirmTitle: isDeletingAccount ? "settings.deleteAccountDeleting".localized : "settings.deleteAccountConfirm".localized,
                    cancelTitle: "settings.deleteAccountKeep".localized,
                    isDestructive: true,
                    onConfirm: {
                        Task { await performAccountDeletion() }
                    },
                    onCancel: {
                        if !isDeletingAccount { showDeleteAccountConfirmation = false }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
    
    private func forceLogout() async {
        do {
            try await authService.signOut(force: true)
            appState.isAuthenticated = false
            appState.currentUser = nil
            dismiss()
        } catch {
            print("Error forcing logout: \(error.localizedDescription)")
        }
    }
    
    private func performAccountDeletion() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        deletionError = nil
        
        do {
            try await authService.deleteAccountPermanently()
            await MainActor.run {
                appState.isAuthenticated = false
                appState.currentUser = nil
                showDeleteAccountConfirmation = false
                showDeleteAccountPanel = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                deletionError = "settings.deleteAccountError".localized
                showDeleteAccountPanel = false
                showDeleteAccountConfirmation = false
            }
        }
        
        isDeletingAccount = false
    }
    
    private var deleteAccountPanel: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 44, height: 5)
                .padding(.top, 8)
            
            Text("settings.deleteAccountWarningTitle".localized)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            Text("settings.deleteAccountWarningMessage".localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            
            VStack(spacing: 12) {
                Button {
                    showDeleteAccountPanel = false
                    showDeleteAccountConfirmation = true
                } label: {
                    Text("settings.deleteAccountConfirm".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                Button {
                    showDeleteAccountPanel = false
                } label: {
                    Text("settings.deleteAccountKeep".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.theme.backgroundDark.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08))
                )
                .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
        )
        .padding(.horizontal, 18)
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
