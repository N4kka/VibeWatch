import SwiftUI

struct LanguageSelector: View {
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
            default: return "🌐 ".localized
        }
    }
    
    var body: some View {
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
            ZStack {
                Circle()
                    .fill(Color.theme.accentOrange.opacity(0.2))
                    .frame(width: 32, height: 32)
                
                Text(flagForLanguage(localizationManager.currentLanguage.id))
                    .font(.system(size: 16))
            }
        }
    }
}

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @StateObject private var notificationService = NotificationService.shared
    @StateObject private var localizationManager = LocalizationManager.shared
    @StateObject private var dailyQuotaManager = DailyQuotaManager.shared
    @State private var showSignUp = false
    @State private var showSignIn = false
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?
    @State private var isUploadingAvatar = false
    @State private var showNotificationAlert = false
    @State private var showDisableConfirmation = false
    @State private var showLogoutConfirmation = false
    @State private var showPlatformSelector = false
    @State private var showSettings = false
    @State private var showChangePassword = false
    @State private var showHelpSupport = false
    @State private var showFeedback = false
    @State private var selectedFeedbackType: FeedbackType?
    @State private var showUpgradePaywall = false
    @State private var pendingNotificationToggle = false
    @AppStorage("selectedPlatforms") private var selectedPlatformsData: Data = Data()
    
    private var selectedPlatforms: Set<StreamingPlatform> {
        get {
            if let decoded = try? JSONDecoder().decode(Set<String>.self, from: selectedPlatformsData) {
                return Set(decoded.compactMap { StreamingPlatform(rawValue: $0) })
            }
            return []
        }
    }

    private var displayNameOrEmail: String {
        guard let user = appState.currentUser else { return "User" }

        // Show display name if it exists and is not empty
        if let displayName = user.displayName, !displayName.isEmpty {
            return displayName
        }

        // Otherwise show email
        return user.email
    }

    private var shouldShowEmailSubtitle: Bool {
        guard let user = appState.currentUser else { return false }

        // Show email as subtitle only if we're showing displayName as main text
        return user.displayName != nil && !(user.displayName?.isEmpty ?? true)
    }
    
    private func togglePlatform(_ platform: StreamingPlatform) {
        var platforms = selectedPlatforms
        if platforms.contains(platform) {
            platforms.remove(platform)
        } else {
            platforms.insert(platform)
        }
        if let encoded = try? JSONEncoder().encode(platforms.map { $0.rawValue }) {
            selectedPlatformsData = encoded
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.theme.background.ignoresSafeArea()
                
                if appState.isAuthenticated {
                    authenticatedView
                } else {
                    unauthenticatedView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    LanguageSelector()
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("profile.done".localized) {
                        dismiss()
                    }
                    .foregroundColor(.theme.textPrimary)
                }
            }
            .overlay {
                if showPlatformSelector {
                    platformSelectorPanel
                }
            }
            .overlay {
                if showLogoutConfirmation {
                    popupOverlayBackground(onTap: {
                        showLogoutConfirmation = false
                    })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    ConfirmationPopup(
                        title: "profile.logoutConfirmationTitle".localized,
                        message: nil,
                        confirmTitle: "common.confirm".localized,
                        cancelTitle: "common.cancel".localized,
                        isDestructive: true,
                        onConfirm: {
                            showLogoutConfirmation = false
                            Task {
                                await handleLogout()
                            }
                        },
                        onCancel: {
                            showLogoutConfirmation = false
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .onAppear {
            if appState.shouldShowSignIn {
                print("🔄 [ProfileView] Auto-opening Sign In sheet")
                showSignIn = true
                // Reset flag
                appState.shouldShowSignIn = false
            }
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
                .environmentObject(appState)
                .environmentObject(authService)
        }
        .sheet(isPresented: $showChangePassword) {
            PasswordResetView(mode: .change, isPresented: $showChangePassword)
                .environmentObject(authService)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
                .environmentObject(appState)
                .environmentObject(authService)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(authService)
        }
        .fullScreenCover(isPresented: $showUpgradePaywall) {
            ProPaywallView(isPresented: $showUpgradePaywall)
                .environmentObject(appState)
                .environmentObject(authService)
                .environmentObject(DailyQuotaManager.shared)
        }
        .sheet(isPresented: $showHelpSupport) {
            HelpSupportSheet()
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet(selectedFeedbackType: $selectedFeedbackType)
        }
        .sheet(item: $selectedFeedbackType) { feedback in
            FeedbackDetailSheet(type: feedback) {
                selectedFeedbackType = nil
                showFeedback = true
            }
        }
    }
    
    private var platformSelectorPanel: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        showPlatformSelector = false
                    }
                }
            
            VStack(spacing: 0) {
                Spacer()
                
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("platforms.title".localized)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.theme.textPrimary)
                        
                        Spacer()
                        
                        Button {
                            withAnimation {
                                showPlatformSelector = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.theme.textSecondary)
                        }
                    }
                    .padding(20)
                    
                    Divider()
                        .background(Color.white.opacity(0.1))
                    
                    // Content
                    VStack(spacing: 0) {
                        // Streaming Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("platforms.streaming".localized)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.theme.textPrimary)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach([StreamingPlatform.netflix, .disney, .prime, .hbo, .apple, .paramount, .hulu, .peacock, .max]) { platform in
                                        PlatformChip(
                                            platform: platform,
                                            isSelected: selectedPlatforms.contains(platform)
                                        ) {
                                            togglePlatform(platform)
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                        
                        Divider()
                            .background(Color.white.opacity(0.1))
                            .padding(.vertical, 16)
                        
                        // Rent Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("platforms.rent".localized)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.theme.textPrimary)
                                .padding(.horizontal, 20)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach([StreamingPlatform.prime, .apple, .youtube, .plex]) { platform in
                                        PlatformChip(
                                            platform: platform,
                                            isSelected: selectedPlatforms.contains(platform)
                                        ) {
                                            togglePlatform(platform)
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                        
                        Divider()
                            .background(Color.white.opacity(0.1))
                            .padding(.vertical, 16)
                        
                        // Buy Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("platforms.buy".localized)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.theme.textPrimary)
                                .padding(.horizontal, 20)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach([StreamingPlatform.prime, .apple, .youtube]) { platform in
                                        PlatformChip(
                                            platform: platform,
                                            isSelected: selectedPlatforms.contains(platform)
                                        ) {
                                            togglePlatform(platform)
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
                .background(Color.theme.backgroundDark.opacity(0.98))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.bottom, 0)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    private var authenticatedView: some View {
        ScrollView {
            VStack(spacing: 12) {
                profileHeader
                
                settingsSection
                
                Button {
                    showLogoutConfirmation = true
                } label: {
                    Text("profile.logout".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 20)
        }
    }
    
    private var unauthenticatedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.circle")
                .font(.system(size: 80))
                .foregroundColor(.theme.textSecondary)
            
            Text("profile.signInToVibeWatch".localized)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            Text("profile.signInDescription".localized)
                .font(.system(size: 16))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                showSignUp = true
            } label: {
                Text("profile.createAccount".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.theme.accentOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            
            Button {
                showSignIn = true
            } label: {
                Text("profile.signIn".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.accentOrange)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.theme.accentOrange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
        }
    }
    
    private var profileHeader: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let avatarURL = appState.currentUser?.avatarURL,
                   let url = URL(string: avatarURL) {
                    CachedAsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                    } placeholder: {
                        ProgressView()
                            .frame(width: 80, height: 80)
                    }
                } else if let selectedImage = selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.theme.textSecondary)
                }
                
                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: "camera.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.theme.accentOrange)
                        .background(
                            Circle()
                                .fill(Color.theme.background)
                                .frame(width: 26, height: 26)
                        )
                }
                .disabled(isUploadingAvatar)
            }
            
            Text(displayNameOrEmail)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)

            if shouldShowEmailSubtitle {
                Text(appState.currentUser?.email ?? "")
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }
            
            if isUploadingAvatar {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .theme.accentOrange))
                        .scaleEffect(0.7)
                    Text("common.uploading".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(selectedImage: $selectedImage)
        }
        .onChange(of: selectedImage) {_, newImage in
            if let image = newImage {
                Task {
                    await uploadAvatar(image)
                }
            }
        }
    }
    
    private var settingsSection: some View {
        VStack(spacing: 12) {
            // Only show upgrade banner if user is not Pro
            if !dailyQuotaManager.isProUser {
                Button {
                    showUpgradePaywall = true
                } label: {
                    ZStack(alignment: .leading) {
                        Image("pro_banner")
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("profile.upgradePro.title".localized)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            Text("profile.upgradePro.subtitle".localized)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 20)
            }

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "bell")
                        .font(.system(size: 20))
                        .foregroundColor(.theme.accentOrange)
                        .frame(width: 24)
                    
                    Text("profile.notifications".localized)
                        .font(.system(size: 16))
                        .foregroundColor(.theme.textPrimary)
                    
                    Spacer()
                    
                    // Use default iOS toggle (iOS 26+ has new design automatically)
                    Toggle("", isOn: $notificationService.notificationsEnabled)
                        .labelsHidden()
                        .tint(.theme.accentOrange)
                }
                .onChange(of: notificationService.notificationsEnabled) {_, newValue in
                    if !pendingNotificationToggle {
                        pendingNotificationToggle = true
                        handleNotificationToggle()
                    }
                }
                .padding()
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                SettingsRow(
                    icon: "play.tv",
                    title: "profile.streamingServices".localized,
                    action: {
                        withAnimation {
                            showPlatformSelector = true
                        }
                    }
                )
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                SettingsRow(
                    icon: "envelope",
                    title: "profile.sendFeedback".localized,
                    action: {
                        showFeedback = true
                    }
                )
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                SettingsRow(
                    icon: "key.fill",
                    title: "profile.changePassword".localized,
                    action: {
                        showChangePassword = true
                    }
                )
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                SettingsRow(
                    icon: "gear",
                    title: "profile.settings".localized,
                    action: {
                        showSettings = true
                    }
                )
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                SettingsRow(
                    icon: "questionmark.circle",
                    title: "profile.helpSupport".localized,
                    action: {
                        showHelpSupport = true
                    }
                )
            }
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
        }
        .alert("notifications.permissionRequired".localized, isPresented: $showNotificationAlert) {
            Button("notifications.openSettings".localized) {
                notificationService.openSettings()
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("notifications.enableInSettings".localized)
        }
        .confirmationDialog("notifications.disableConfirmation".localized, isPresented: $showDisableConfirmation, titleVisibility: .visible) {
            Button("notifications.disableButton".localized, role: .destructive) {
                Task {
                    await notificationService.disableNotifications()
                }
            }
            Button("common.cancel".localized, role: .cancel) {
                // Reset toggle back to enabled
                notificationService.notificationsEnabled = true
            }
        } message: {
            Text("notifications.disableMessage".localized)
        }
    }
    
    private func handleNotificationToggle() {
        Task {
            defer { pendingNotificationToggle = false }
            
            if notificationService.notificationsEnabled {
                // User wants to enable notifications
                let success = await notificationService.enableNotifications()
                
                if !success {
                    // Permission denied - reset toggle and show alert
                    await MainActor.run {
                        notificationService.notificationsEnabled = false
                        showNotificationAlert = true
                    }
                }
            } else {
                // User wants to disable notifications - show confirmation
                await MainActor.run {
                    showDisableConfirmation = true
                }
            }
        }
    }
    
    private func handleLogout() async {
        do {
            try await authService.signOut()
            appState.isAuthenticated = false
            appState.currentUser = nil
        } catch {
            print("Error logging out: \(error.localizedDescription)")
        }
    }
    
    private func uploadAvatar(_ image: UIImage) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        
        do {
            // Compress image to JPEG data
            guard let imageData = image.jpegData(compressionQuality: 0.7) else {
                print("❌ Failed to convert image to data")
                return
            }
            
            // Upload to Supabase Storage
            let avatarURL = try await authService.uploadAvatar(imageData: imageData)
            
            // Update app state
            appState.currentUser?.avatarURL = avatarURL
            
            print("✅ Avatar uploaded and profile updated")
        } catch {
            print("❌ Error uploading avatar: \(error.localizedDescription)")
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    var iconColor: Color = .theme.accentOrange
    var textColor: Color = .theme.textPrimary
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(iconColor)
                    .frame(width: 30)
                
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(textColor)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }
            .padding()
        }
    }
}

struct HelpSupportSheet: View {
    private let privacyURL = URL(string: "https://vibewatch.vercel.app/privacy")!
    private let termsOfUseURL = URL(string: "https://vibewatch.vercel.app/terms")!

    private var faqItems: [FAQItem] {
        [
            FAQItem(
                question: "profile.faq.question1".localized,
                answer: "profile.faq.answer1".localized
            ),
            FAQItem(
                question: "profile.faq.question2".localized,
                answer: "profile.faq.answer2".localized
            ),
            FAQItem(
                question: "profile.faq.question3".localized,
                answer: "profile.faq.answer3".localized
            ),
            FAQItem(
                question: "profile.faq.question4".localized,
                answer: "profile.faq.answer4".localized
            ),
            FAQItem(
                question: "profile.faq.question5".localized,
                answer: "profile.faq.answer5".localized
            )
        ]
    }

    @State private var expandedFAQ: UUID?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("profile.aboutUs".localized)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.theme.textPrimary)
                        Text("profile.aboutUsDescription".localized)
                            .font(.system(size: 14))
                            .foregroundColor(.theme.textSecondary)
                        Text("profile.tmdbAttribution".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.theme.textSecondary)
                            .padding(.top, 2)
                    }
                    .padding()
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("profile.faqs".localized)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.theme.textPrimary)

                        LazyVGrid(columns: [GridItem(.flexible())], spacing: 12) {
                            ForEach(faqItems) { item in
                                FAQChip(
                                    item: item,
                                    isExpanded: expandedFAQ == item.id
                                ) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        if expandedFAQ == item.id {
                                            expandedFAQ = nil
                                        } else {
                                            expandedFAQ = item.id
                                        }
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("profile.legal".localized)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.theme.textPrimary)

                        VStack(spacing: 10) {
                            Link(destination: privacyURL) {
                                HStack {
                                    Text("profile.privacyPolicy".localized)
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .font(.system(size: 14))
                                .foregroundColor(.theme.textPrimary)
                            }

                            Divider()

                            Link(destination: termsOfUseURL) {
                                HStack {
                                    Text("profile.termsOfUse".localized)
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .font(.system(size: 14))
                                .foregroundColor(.theme.textPrimary)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
            }
            .background(Color.theme.background)
            .navigationTitle("profile.helpSupport".localized)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

private struct FAQItem: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

private struct FAQChip: View {
    let item: FAQItem
    let isExpanded: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text(item.question)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.theme.textSecondary)
                }
                
                if isExpanded {
                    Text(item.answer)
                        .font(.system(size: 12))
                        .foregroundColor(.theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isExpanded ? Color.theme.accentOrange : Color.white.opacity(0.08), lineWidth: isExpanded ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

@MainActor
struct FeedbackType: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let iconName: String
    
    static let suggest = FeedbackType(
        id: "suggest",
        title: "profile.feedback.suggestFeature".localized,
        description: "profile.feedback.suggestFeatureDescription".localized,
        iconName: "iphone"
    )
    static let bug = FeedbackType(
        id: "bug",
        title: "profile.feedback.reportBug".localized,
        description: "profile.feedback.reportBugDescription".localized,
        iconName: "ant.fill"
    )
    static let other = FeedbackType(
        id: "other",
        title: "profile.feedback.other".localized,
        description: "profile.feedback.otherDescription".localized,
        iconName: "gearshape.fill"
    )
    
    static var all: [FeedbackType] { [.suggest, .bug, .other] }
}

struct FeedbackSheet: View {
    @Binding var selectedFeedbackType: FeedbackType?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(FeedbackType.all) { type in
                    Button {
                        selectedFeedbackType = type
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: type.iconName)
                                .font(.system(size: 20))
                                .foregroundColor(.theme.accentOrange)
                                .frame(width: 24)
                            Text(type.title)
                                .font(.system(size: 16))
                                .foregroundColor(.theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.theme.textSecondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Color.theme.background)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.theme.background)
            .navigationTitle("profile.sendFeedback".localized)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.fraction(0.5), .large])
        .presentationDragIndicator(.visible)
    }
}

struct FeedbackDetailSheet: View {
    let type: FeedbackType
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var onCancel: (() -> Void)? = nil
    @State private var message = ""
    @State private var keepUpdated = true
    @State private var isSending = false
    @State private var sendError: String?
    @State private var sendSuccess = false
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(type.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.theme.textPrimary)
                    Text(type.description)
                        .font(.system(size: 14))
                        .foregroundColor(.theme.textSecondary)
                }
                
                TextEditor(text: $message)
                    .frame(minHeight: 120, maxHeight: 160)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.08))
                    )
                    .foregroundColor(.theme.textPrimary)
                
                Toggle(isOn: $keepUpdated) {
                    Text("profile.feedback.keepUpdated".localized)
                        .foregroundColor(.theme.textPrimary)
                }
                .tint(.theme.accentOrange)
                
                if let sendError {
                    Text(sendError)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
                
                if sendSuccess {
                    Text("profile.feedback.sent".localized)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.green)
                }
                
                Spacer()
                
                Button {
                    Task { await sendFeedback() }
                } label: {
                    HStack {
                        if isSending {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("profile.feedback.sendButton".localized)
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundColor(.white)
                    .background(canSend ? Color.theme.accentOrange : Color.theme.accentOrange.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canSend || isSending)
            }
            .padding(20)
            .background(Color.theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("profile.cancel".localized) {
                        if let onCancel {
                            onCancel()
                        } else {
                            dismiss()
                        }
                    }
                        .foregroundColor(.theme.textPrimary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.fraction(0.5), .large])
        .presentationDragIndicator(.visible)
    }
    
    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func sendFeedback() async {
        guard canSend else { return }
        isSending = true
        sendError = nil
        sendSuccess = false
        
        let subject = type.title
        let body = message
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        let mailtoString = "mailto:startingvibe2025@gmail.com?subject=\(encodedSubject)&body=\(encodedBody)"
        
        guard let url = URL(string: mailtoString) else {
            sendError = "profile.feedback.invalidEmail".localized
            isSending = false
            return
        }
        
        openURL(url)
        sendSuccess = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            dismiss()
        }
        
        isSending = false
    }
}
