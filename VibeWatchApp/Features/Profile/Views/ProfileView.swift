import SwiftUI

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var notificationService = NotificationService.shared
    @StateObject private var localizationManager = LocalizationManager.shared
    @State private var showSignUp = false
    @State private var showSignIn = false
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?
    @State private var isUploadingAvatar = false
    @State private var showNotificationAlert = false
    @State private var showDisableConfirmation = false
    @State private var showPlatformSelector = false
    @State private var showSettings = false
    @AppStorage("selectedPlatforms") private var selectedPlatformsData: Data = Data()
    
    private var selectedPlatforms: Set<StreamingPlatform> {
        get {
            if let decoded = try? JSONDecoder().decode(Set<String>.self, from: selectedPlatformsData) {
                return Set(decoded.compactMap { StreamingPlatform(rawValue: $0) })
            }
            return []
        }
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
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
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
            VStack(spacing: 24) {
                profileHeader
                
                settingsSection
                
                Button {
                    Task {
                        await handleLogout()
                    }
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
                    AsyncImage(url: url) { image in
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
            
            Text(appState.currentUser?.displayName ?? "User")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.theme.textPrimary)
            
            if let email = appState.currentUser?.email {
                Text(email)
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
        .onChange(of: selectedImage) { newImage in
            if let image = newImage {
                Task {
                    await uploadAvatar(image)
                }
            }
        }
    }
    
    private var settingsSection: some View {
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
                
                Toggle("", isOn: $notificationService.notificationsEnabled)
                    .labelsHidden()
                    .tint(.theme.accentOrange)
                    .onChange(of: notificationService.notificationsEnabled) { newValue in
                        Task {
                            if newValue {
                                // User wants to enable notifications
                                let success = await notificationService.enableNotifications()
                                
                                if !success {
                                    // Permission denied - reset toggle and show alert
                                    notificationService.notificationsEnabled = false
                                    showNotificationAlert = true
                                }
                            } else {
                                // User wants to disable notifications - show confirmation
                                showDisableConfirmation = true
                            }
                        }
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
                action: {}
            )
        }
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
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
    
    private func handleLogout() async {
        do {
            try await AuthService.shared.signOut()
            appState.isAuthenticated = false
            appState.currentUser = nil
            
            // Show sign up screen instead of just dismissing
            unauthenticatedView
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
            let avatarURL = try await AuthService.shared.uploadAvatar(imageData: imageData)
            
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
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.theme.accentOrange)
                    .frame(width: 30)
                
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(.theme.textPrimary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(.theme.textSecondary)
            }
            .padding()
        }
    }
}
