import SwiftUI
import StoreKit
import RevenueCat

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @StateObject private var localizationManager = LocalizationManager.shared
    @State private var showDeleteAccountPanel = false
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deletionError: String?
    @AppStorage("analytics.isEnabled") private var analyticsEnabled: Bool = true

    // Cache Management
    @State private var showCacheSizeOptions = false
    @State private var showPrefetchOptions = false
    @State private var showClearCacheConfirmation = false
    @State private var currentUser: User?
    @State private var selectedCacheSize: ImageCacheService.CacheSizePreference = .medium
    @State private var selectedPrefetchOption: ImageCacheService.ImagePrefetchOption = .wifiOnly

    // Transaction listener for code redemption
    @State private var transactionListenerTask: Task<Void, Never>?

    private var cacheSizeDescription: String {
        selectedCacheSize.rawValue
    }

    private var prefetchOptionDescription: String {
        selectedPrefetchOption.rawValue
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    HStack {
                        BackCircleButton { dismiss() }

                    Spacer()

                    Text("settings.title".localized)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.theme.textPrimary)

                    Spacer()

                    // Gemello invisibile per tenere il titolo centrato
                    BackCircleButton {}
                        .opacity(0)
                        .disabled(true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                ScrollView {
                    VStack(spacing: 16) {
                        // Privacy / Analytics Section
                        VStack(spacing: 16) {
                            Text("settings.privacy.title".localized)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)

                            HStack(spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(Color.theme.accentOrange.opacity(0.2))
                                        .frame(width: 44, height: 44)

                                    Image(systemName: "chart.bar.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.theme.accentOrange)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("settings.analytics.share".localized)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.theme.textPrimary)

                                    Text("settings.analytics.share.description".localized)
                                        .font(.system(size: 14))
                                        .foregroundColor(.theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer()

                                Toggle("", isOn: $analyticsEnabled)
                                    .labelsHidden()
                                    .tint(.theme.accentOrange)
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .onChange(of: analyticsEnabled) { _, newValue in
                            AnalyticsService.shared.setEnabled(newValue)
                        }

                        // Social feed M1: visibilità nel feed attività. La sezione è
                        // autocontenuta (Features/Social) — qui solo l'aggancio, e solo per
                        // chi ha una sessione: il flag vive sul profilo remoto.
                        if authService.currentUser != nil {
                            SocialSettingsSection()

                            // Moderazione M2: la porta verso gli utenti bloccati. La riga vive
                            // qui e non dentro SocialSettingsSection perché quella sezione è di
                            // Features/Social (proprietario diverso); il linguaggio visivo è
                            // quello delle altre righe di questa schermata.
                            NavigationLink {
                                BlockedUsersView()
                            } label: {
                                HStack(spacing: 16) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.theme.accentOrange.opacity(0.2))
                                            .frame(width: 44, height: 44)

                                        Image(systemName: "hand.raised.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.theme.accentOrange)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("settings.blockedUsers.title".localized)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.theme.textPrimary)

                                        Text("settings.blockedUsers.description".localized)
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

                        // Notifications Section
                        if let userId = authService.currentUser?.id {
                            VStack(spacing: 16) {
                                Text("settings.notifications.title".localized)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.theme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 12)

                                NavigationLink {
                                    NotificationPreferencesView()
                                } label: {
                                    HStack(spacing: 16) {
                                        ZStack {
                                            Circle()
                                                .fill(Color.theme.accentOrange.opacity(0.2))
                                                .frame(width: 44, height: 44)

                                            Image(systemName: "bell.fill")
                                                .font(.system(size: 20))
                                                .foregroundColor(.theme.accentOrange)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("settings.notifications.manage".localized)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundColor(.theme.textPrimary)

                                            Text("settings.notifications.description".localized)
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

                        // Analytics Dashboard Section
                        if (authService.currentUser?.id) != nil {
                            VStack(spacing: 16) {
                                Text("settings.analytics.title".localized)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.theme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 12)

                                NavigationLink {
                                    AnalyticsDashboardView()
                                } label: {
                                    HStack(spacing: 16) {
                                        ZStack {
                                            Circle()
                                                .fill(Color.theme.accentOrange.opacity(0.2))
                                                .frame(width: 44, height: 44)

                                            Image(systemName: "chart.bar.fill")
                                                .font(.system(size: 20))
                                                .foregroundColor(.theme.accentOrange)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("settings.analytics.viewStats".localized)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundColor(.theme.textPrimary)

                                            Text("settings.analytics.description".localized)
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

#if DEBUG
                        // Analytics Debug Section
                        VStack(spacing: 16) {
                            Text("Debug")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)

                            NavigationLink {
                                AnalyticsHealthDebugView()
                            } label: {
                                HStack(spacing: 16) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.theme.accentOrange.opacity(0.2))
                                            .frame(width: 44, height: 44)

                                        Image(systemName: "waveform.path.ecg")
                                            .font(.system(size: 20))
                                            .foregroundColor(.theme.accentOrange)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Analytics Health")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.theme.textPrimary)

                                        Text("Inspect recent events and PostHog queue.")
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
#endif

                        // Cache Management Section
                        VStack(spacing: 16) {
                            Text("settings.cacheManagement.title".localized)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)
                            
                            // Cache Size Preference
                            SettingItemView(
                                icon: "folder.fill",
                                title: "settings.cacheManagement.cacheSize".localized,
                                value: cacheSizeDescription,
                                action: { showCacheSizeOptions = true }
                            )
                            
                            // Image Prefetch Option
                            SettingItemView(
                                icon: "arrow.down.circle.fill",
                                title: "settings.cacheManagement.prefetchOption".localized,
                                value: prefetchOptionDescription,
                                action: { showPrefetchOptions = true }
                            )
                            
                            // Clear Cache Button
                            Button {
                                showClearCacheConfirmation = true
                            } label: {
                                HStack(spacing: 16) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.theme.accentOrange.opacity(0.2))
                                            .frame(width: 44, height: 44)
                                        
                                        Image(systemName: "trash.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.theme.accentOrange)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("settings.cacheManagement.clearCache".localized)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.theme.textPrimary)
                                        
                                        Text("settings.cacheManagement.clearCacheWarning".localized)
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
                        .padding(.top, 12)

                        // Redeem Code Section
                        VStack(spacing: 0) {
                            Button {
                                presentOfferCodeRedemption()
                            } label: {
                                HStack(spacing: 16) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.theme.accentOrange.opacity(0.2))
                                            .frame(width: 44, height: 44)

                                        Image(systemName: "ticket.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.theme.accentOrange)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("settings.redeemCode".localized)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.theme.textPrimary)

                                        Text("settings.redeemCode.description".localized)
                                            .font(.system(size: 14))
                                            .foregroundColor(.theme.textSecondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14))
                                        .foregroundColor(.theme.textSecondary)
                                }
                                .padding(16)
                            }
                        }
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 8)

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
        .onAppear {
            AnalyticsService.shared.logScreenView(screenName: "Settings")
            currentUser = authService.currentUser
            // Load cache preferences from UserDefaults
            selectedCacheSize = ImageCacheService.shared.getCurrentCacheSizePreference()
            selectedPrefetchOption = ImageCacheService.shared.getCurrentImagePrefetchOption()
            Logger.info("[Settings] Loaded cache size preference: \(selectedCacheSize.rawValue)")
            Logger.info("[Settings] Loaded prefetch option: \(selectedPrefetchOption.rawValue)")
        }
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
            if showCacheSizeOptions {
                popupOverlayBackground(onTap: { showCacheSizeOptions = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                cacheSizeOptionsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
            }
        }
        .overlay {
            if showPrefetchOptions {
                popupOverlayBackground(onTap: { showPrefetchOptions = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                prefetchOptionsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
            }
        }
        .overlay {
            if showClearCacheConfirmation {
                clearCacheConfirmation
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
        .navigationViewStyle(.stack)
    }

    private func updateCacheSizePreference(_ preference: ImageCacheService.CacheSizePreference) {
        // Update UI state immediately
        selectedCacheSize = preference

        // Store in UserDefaults (device-specific, no need for cloud sync)
        ImageCacheService.shared.setCacheSizePreference(preference)

        Logger.info("[Settings] Cache size preference updated to \(preference.rawValue)")
    }

    private func updatePrefetchOption(_ option: ImageCacheService.ImagePrefetchOption) {
        // Update UI state immediately
        selectedPrefetchOption = option

        // Store in UserDefaults (device-specific, no need for cloud sync)
        ImageCacheService.shared.setImagePrefetchOption(option)

        Logger.info("[Settings] Prefetch option updated to \(option.rawValue)")
    }
    
    private func clearCache() {
        ImageCacheService.shared.clearCache()

        // Trigger auto-recaching if prefetch is enabled
        let prefetchOption = selectedPrefetchOption
        Task {
            let shouldRecache = prefetchOption != .never

            if shouldRecache {
                // Check if we should prefetch based on current network conditions
                let canPrefetch = await ImageCacheService.shared.shouldPrefetchImages(preference: prefetchOption)

                if canPrefetch {
                    // Trigger recaching of current content
                    await triggerRecaching()
                }
            }
        }

        Logger.info("[Settings] Cache cleared successfully")
    }

    private func triggerRecaching() async {
        Logger.info("[Cache] Starting auto-recaching after cache clear...")

        // Only recache if user is PRO (since prefetching is a PRO feature)
        let isProUser = await ClipQuotaService.shared.checkIsProUser()

        if isProUser {
            // Trigger daily content prefetch with force flag to ignore daily limit
            await DailyContentPrefetchService.shared.executeDailyPrefetch(force: true)
            Logger.info("[Cache] Recaching completed")
        } else {
            Logger.info("[Cache] Skipping recache - User is not PRO")
        }
    }
    
    private func forceLogout() async {
        do {
            try await authService.signOut(force: true)
            appState.isAuthenticated = false
            appState.currentUser = nil
            dismiss()
        } catch {
            Logger.error("[Settings] Error forcing logout: \(error.localizedDescription)")
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

    /// Present Apple's native offer code redemption sheet
    private func presentOfferCodeRedemption() {
        // Start listening for transactions before showing the sheet
        startTransactionListener()

        // Use StoreKit's native offer code redemption sheet
        // This opens Apple's system UI for entering promo/offer codes
        SKPaymentQueue.default().presentCodeRedemptionSheet()
        Logger.info("[Settings] Presenting offer code redemption sheet")
    }

    /// Listen for StoreKit transactions after code redemption
    private func startTransactionListener() {
        // Cancel any existing listener
        transactionListenerTask?.cancel()

        transactionListenerTask = Task {
            // Listen for new transactions from StoreKit 2
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction):
                    Logger.info("[Settings] Transaction detected: \(transaction.productID)")

                    // Sync with RevenueCat to update entitlements
                    await syncPurchasesWithRevenueCat()

                    // Always finish the transaction
                    await transaction.finish()
                case .unverified(_, let error):
                    Logger.warning("[Settings] Transaction verification failed: \(error)")
                }
            }
        }
    }

    /// Sync purchases with RevenueCat after code redemption
    private func syncPurchasesWithRevenueCat() async {
        do {
            // Sync purchases forces RevenueCat to check with Apple for new transactions
            let customerInfo = try await Purchases.shared.syncPurchases()
            let isPro = customerInfo.entitlements[AppConstants.RevenueCat.proEntitlementID]?.isActive == true

            if isPro {
                Logger.info("[Settings] Code redeemed successfully! PRO status activated")
                await MainActor.run {
                    DailyQuotaManager.shared.upgradeToPro()
                }
                // Also refresh the ClipQuotaService to update its cached status
                await ClipQuotaService.shared.checkIsProUser()
            }
        } catch {
            Logger.warning("[Settings] Failed to sync purchases: \(error)")
            // Still try to check PRO status directly
            await ClipQuotaService.shared.checkIsProUser()
        }
    }
    
    // Cache Size Options Panel
    private var cacheSizeOptionsPanel: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 44, height: 5)
                .padding(.top, 8)
            
            Text("settings.cacheManagement.cacheSizeTitle".localized)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            Text("settings.cacheManagement.cacheSizeDescription".localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            
            VStack(spacing: 12) {
                ForEach(ImageCacheService.CacheSizePreference.allCases, id: \.self) { option in
                    Button {
                        updateCacheSizePreference(option)
                        showCacheSizeOptions = false
                    } label: {
                        HStack {
                            Text(option.rawValue)
                                .font(.system(size: 16))
                                .foregroundColor(.theme.textPrimary)

                            Spacer()

                            if selectedCacheSize == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.theme.accentOrange)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 12)
            
            Button {
                showCacheSizeOptions = false
            } label: {
                Text("common.cancel".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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
    
    // Prefetch Options Panel
    private var prefetchOptionsPanel: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 44, height: 5)
                .padding(.top, 8)
            
            Text("settings.cacheManagement.prefetchTitle".localized)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.theme.textPrimary)
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            Text("settings.cacheManagement.prefetchDescription".localized)
                .font(.system(size: 14))
                .foregroundColor(.theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            
            VStack(spacing: 12) {
                ForEach(ImageCacheService.ImagePrefetchOption.allCases, id: \.self) { option in
                    Button {
                        updatePrefetchOption(option)
                        showPrefetchOptions = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.rawValue)
                                    .font(.system(size: 16))
                                    .foregroundColor(.theme.textPrimary)

                                if option == .never {
                                    Text("settings.cacheManagement.prefetchNeverWarning".localized)
                                        .font(.system(size: 12))
                                        .foregroundColor(.theme.accentOrange)
                                }
                            }

                            Spacer()

                            if selectedPrefetchOption == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.theme.accentOrange)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 12)
            
            Button {
                showPrefetchOptions = false
            } label: {
                Text("common.cancel".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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
    
    // Clear Cache Confirmation
    private var clearCacheConfirmation: some View {
        ConfirmationPopup(
            title: "settings.cacheManagement.clearCacheConfirmTitle".localized,
            message: "settings.cacheManagement.clearCacheConfirmMessage".localized,
            confirmTitle: "settings.cacheManagement.clearCacheConfirm".localized,
            cancelTitle: "common.cancel".localized,
            isDestructive: true,
            onConfirm: {
                clearCache()
                showClearCacheConfirmation = false
            },
            onCancel: {
                showClearCacheConfirmation = false
            }
        )
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
    @State private var searchText = ""

    private var filteredCountries: [Country] {
        guard !searchText.isEmpty else { return Country.all }
        return Country.all.filter { country in
            let language = Language.findByCode(country.nativeLanguageCode)
            return countryDisplayName(country).localizedCaseInsensitiveContains(searchText)
                || country.name.localizedCaseInsensitiveContains(searchText)
                || language?.nativeName.localizedCaseInsensitiveContains(searchText) == true
                || language?.name.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private func countryDisplayName(_ country: Country) -> String {
        Locale(identifier: localizationManager.currentLanguage.id)
            .localizedString(forRegionCode: country.id) ?? country.name
    }

    private func rowTitle(for country: Country) -> String {
        let languageName = Language.findByCode(country.nativeLanguageCode)?.nativeName
            ?? country.nativeLanguageCode.uppercased()
        return "\(country.flag) \(languageName) (\(countryDisplayName(country)))"
    }
    
    var body: some View {
        ZStack {
            Color.theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    BackCircleButton { dismiss() }

                    Spacer()

                    Text("profile.languageCountry".localized)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.theme.textPrimary)

                    Spacer()

                    // Gemello invisibile per tenere il titolo centrato
                    BackCircleButton {}
                        .opacity(0)
                        .disabled(true)
                }
                .padding(20)
                
                Divider()
                    .background(Color.white.opacity(0.1))

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.theme.textSecondary)
                    TextField("common.search".localized, text: $searchText)
                        .foregroundColor(.theme.textPrimary)
                }
                .padding(12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                // Un'unica scelta imposta sia il paese sia la sua lingua principale.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredCountries) { country in
                            Button {
                                localizationManager.setCountry(country)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Text(rowTitle(for: country))
                                        .font(.system(size: 16))
                                        .foregroundColor(.theme.textPrimary)
                                        .multilineTextAlignment(.leading)

                                    Spacer()

                                    if country.id == localizationManager.currentCountry.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.theme.accentOrange)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                            }

                            if country.id != filteredCountries.last?.id {
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
