import SwiftUI
import RevenueCat

@main
struct VibeWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var localizationManager = LocalizationManager.shared
    @StateObject private var syncWorker = SyncWorker.shared
    @StateObject private var sqliteDB = SQLiteService.shared
    @StateObject private var appNavigationManager = AppNavigationManager.shared
    @StateObject private var authService = AuthService.shared
    @StateObject private var quotaManager = DailyQuotaManager.shared
    
    init() {
        // Configure RevenueCat with appropriate log level
        RevenueCatService.shared.applyCurrentLogLevel()
        Purchases.configure(withAPIKey: Config.revenueCatAPIKey)
        
        // Force load localizations before any views are created
        _ = LocalizationManager.shared
        
        // Initialize offline-first database
        print("🗄️ [App] Initializing SQLite database...")
        print("✅ [RevenueCat] Configured with API key")
    }
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .environmentObject(localizationManager)
                .environmentObject(syncWorker)
                .environmentObject(appNavigationManager)
                .environmentObject(authService)
                .environmentObject(quotaManager)
                .preferredColorScheme(.dark)
                .task {
                    // Start background sync worker
                    await syncWorker.startPeriodicSync()
                    print("🔄 [App] Background sync started")
                }
                .onOpenURL { url in
                    // Handle deep links from URL schemes (e.g., OAuth)
                    print("📱 Deep link received via URL (SwiftUI): \(url.absoluteString)")
                    Task {
                        do {
                            try await AuthService.shared.handleAuthCallback(url: url)
                            appState.isAuthenticated = AuthService.shared.isAuthenticated
                            appState.currentUser = AuthService.shared.currentUser
                        } catch {
                            print("❌ Error handling deep link from URL: \(error.localizedDescription)")
                        }
                    }
                }
                // Handle deep links from push notifications
                .sheet(item: $appNavigationManager.deepLinkTarget) { target in
                    Group {
                        if target.mediaType == "movie" {
                            MovieDetailView(movieId: target.mediaId)
                        } else if target.mediaType == "tv" {
                            TVShowDetailView(tvShowId: target.mediaId)
                        }
                    }
                    .onDisappear {
                        appNavigationManager.clearDeepLinkTarget()
                    }
                }
                .fullScreenCover(item: $appState.updateRequirement) { requirement in
                    UpdateRequiredView(requirement: requirement)
                }
        }
    }
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState() // Singleton for global access if needed
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var showSuccessToast = false
    @Published var showErrorToast = false
    @Published var toastMessage = ""
    @Published var isPreloading = true // Track splash state
    @Published var shouldShowSignIn = false // Trigger for redirecting to sign in flow
    @Published var updateRequirement: UpdateRequirement?
    
    private let authService: AuthService
    private let dataCoordinator = DataCoordinator.shared
    
    init(authService: AuthService = .shared) {
        self.authService = authService

        // Immediately load from cached auth state (synchronous)
        self.isAuthenticated = authService.isAuthenticated
        self.currentUser = authService.currentUser
        print("📱 [AppState] Initialized with auth state: authenticated=\(isAuthenticated), user=\(currentUser?.email ?? "nil")")

        Task {
            await checkForRequiredUpdate()
            await checkAuthState()

            // CRITICAL: Sync user data from Supabase on every app launch
            await performFullSyncOnLaunch()

            await preloadContent()
            await RevenueCatService.shared.refreshOfferings()

            // Check and execute daily prefetch for PRO users
            await DailyContentPrefetchService.shared.checkAndExecuteDailyPrefetch()

            // Schedule smart notifications on app launch (background tasks are unreliable)
            await scheduleSmartNotificationsIfNeeded()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.checkForRequiredUpdate()

                // CRITICAL: Sync user data when returning to foreground
                await self?.performSyncOnForegroundResume()

                // Also check for notifications when returning to foreground
                await self?.scheduleSmartNotificationsIfNeeded()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func checkAuthState() async {
        await authService.checkAuthState()
        self.isAuthenticated = authService.isAuthenticated
        self.currentUser = authService.currentUser
        print("🔄 [AppState] Updated auth state: authenticated=\(isAuthenticated), user=\(currentUser?.email ?? "nil")")
    }

    /// Perform full sync from Supabase on app launch
    /// This ensures data persists across days and devices
    private func performFullSyncOnLaunch() async {
        guard isAuthenticated, let userId = currentUser?.id else {
            print("📱 [AppState] Skipping sync - not authenticated")
            return
        }

        print("🔄 [AppState] Performing full sync on app launch...")

        // Check onboarding state from profile first
        await checkOnboardingFromProfile()

        // Sync gamification state first (XP, level, streak, badges)
        await GamificationService.shared.loadUserState(userId: userId)

        // Sync lists from Supabase
        await ListManager.shared.syncListsForAuthenticatedUser()

        // Process any pending outbox operations
        await SyncWorker.shared.forceSyncNow()

        print("✅ [AppState] Full sync completed on app launch")
    }

    /// Sync user data when app returns to foreground
    /// Throttled to avoid excessive syncs
    private func performSyncOnForegroundResume() async {
        guard isAuthenticated, let userId = currentUser?.id else { return }

        // Throttle: Only sync if last sync was > 2 minutes ago
        let lastSyncKey = "lastForegroundSyncTime"
        let lastSync = UserDefaults.standard.double(forKey: lastSyncKey)
        let now = Date().timeIntervalSince1970
        let twoMinutes: TimeInterval = 2 * 60

        guard now - lastSync > twoMinutes else {
            print("📱 [AppState] Skipping foreground sync - synced recently")
            return
        }

        UserDefaults.standard.set(now, forKey: lastSyncKey)
        print("🔄 [AppState] Performing sync on foreground resume...")

        // Sync gamification state (may have changed on another device)
        await GamificationService.shared.loadUserState(userId: userId)

        // Sync lists
        await ListManager.shared.syncListsForAuthenticatedUser()

        // Process pending outbox
        await SyncWorker.shared.forceSyncNow()

        print("✅ [AppState] Foreground sync completed")
    }

    /// Check if user completed onboarding on another device
    private func checkOnboardingFromProfile() async {
        guard isAuthenticated else { return }

        // If already completed locally, sync to profile if needed
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            // Ensure it's synced to profile
            Task {
                do {
                    try await SupabaseService.shared.updateUserProfile([
                        "onboarding_completed": true,
                        "onboarding_completed_at": ISO8601DateFormatter().string(from: Date())
                    ])
                } catch {
                    print("⚠️ [AppState] Failed to sync onboarding state: \(error)")
                }
            }
            return
        }

        // Check if completed on another device
        do {
            if let profile = try await SupabaseService.shared.fetchUserProfile(),
               let completed = profile["onboarding_completed"] as? Bool,
               completed {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                print("✅ [AppState] Onboarding already completed on another device")
            }
        } catch {
            print("⚠️ [AppState] Failed to check onboarding from profile: \(error)")
        }
    }

    /// Schedule smart notifications when user is authenticated
    /// Called on app launch and when returning to foreground
    private func scheduleSmartNotificationsIfNeeded() async {
        guard let userId = currentUser?.id else {
            print("📳 [AppState] Skipping notification check - no authenticated user")
            return
        }

        // Throttle: Only run once per 30 minutes
        let lastRunKey = "lastSmartNotificationCheck"
        let lastRun = UserDefaults.standard.double(forKey: lastRunKey)
        let now = Date().timeIntervalSince1970
        let thirtyMinutes: TimeInterval = 30 * 60

        if now - lastRun < thirtyMinutes {
            print("📳 [AppState] Skipping notification check - ran recently")
            return
        }

        UserDefaults.standard.set(now, forKey: lastRunKey)
        print("📳 [AppState] Triggering smart notification check for user: \(userId)")

        await NotificationBackgroundTask.shared.triggerImmediately()
    }

    private func checkForRequiredUpdate() async {
        updateRequirement = await UpdateCheckService.shared.checkForRequiredUpdate()
    }
    
    private func preloadContent() async {
        isPreloading = true
        
        // Check if initial data migration is needed
        if !UserDefaults.standard.bool(forKey: "initialDataPopulated") {
            print("📥 [App] First launch detected - migrating data from Supabase to SQLite...")
            await DatabaseMigrationService.shared.migrateInitialData()
        }
        
        // Sync new content from Supabase (incremental sync)
        print("🔄 [App] Syncing new content from Supabase...")
        try? await SyncService.shared.syncNewContent()
        
        // Optimized parallel preload: Discovery content + 5 initial clips
        // Then background task for 20 more clips
        print("🚀 Starting optimized preload (parallel tasks)...")
        await dataCoordinator.initializeApp()
        
        // Ensure discovery content exists (fetch from TMDB if needed)
        await ensureDiscoveryContentExists()

        // Pre-warm the personalized discovery cache so the Discovery tab loads instantly
        print("📺 [App] Pre-warming Discovery personalization cache...")
        let profile = await UserPreferenceManager.shared.aggregatePreferences()
        do {
            // We call this to trigger the cache-miss logic (API fetch + DB cache) if needed.
            // When DiscoveryViewModel calls this later, it will hit the DB cache instantly.
            _ = try await DiscoveryPersonalizationService.shared.generatePersonalizedCarousels(
                userProfile: profile,
                forceRefresh: false
            )
            print("✅ [App] Discovery personalization pre-warmed successfully")
        } catch {
            print("⚠️ [App] Failed to pre-warm Discovery personalization: \(error)")
        }
        
        isPreloading = false
    }
    
    /// Ensure discovery content exists in local database
    private func ensureDiscoveryContentExists() async {
        do {
            // Try to get discovery content (will use cache if available)
            let content = try await DiscoveryCacheService.shared.getDiscoveryContent()
            
            // Check if we have sufficient content
            let totalContent = content.trending.count + content.popular.count + content.topRated.count + content.tv.count
            
            if totalContent > 0 {
                print("✅ [App] Discovery content exists: \(totalContent) items")
            } else {
                print("⚠️ [App] Discovery cache is empty - fetching fresh from TMDB...")
                // Cache is empty, force refresh from TMDB
                try await DiscoveryCacheService.shared.refreshContent()
                print("✅ [App] Discovery content populated from TMDB")
            }
        } catch {
            print("⚠️ [App] Failed to load discovery content: \(error)")
        }
    }
}
