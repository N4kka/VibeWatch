import SwiftUI
import RevenueCat

@main
struct VibeWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var localizationManager = LocalizationManager.shared
    @StateObject private var syncEngine = SyncEngine.shared
    @StateObject private var sqliteDB = SQLiteService.shared
    @StateObject private var appNavigationManager = AppNavigationManager.shared
    @StateObject private var authService = AuthService.shared
    @StateObject private var quotaManager = DailyQuotaManager.shared
    @StateObject private var dependencies = DependencyContainer.shared
    
    init() {
        // Configure RevenueCat with appropriate log level
        RevenueCatService.shared.applyCurrentLogLevel()
        Purchases.configure(withAPIKey: Config.revenueCatAPIKey)
        
        // Force load localizations before any views are created
        _ = LocalizationManager.shared
        
        // Initialize offline-first database
        Logger.info("[App] Initializing SQLite database...")
        Logger.info("[App] RevenueCat configured with API key")
    }
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .environmentObject(localizationManager)
                .environmentObject(syncEngine)
                .environmentObject(appNavigationManager)
                .environmentObject(authService)
                .environmentObject(quotaManager)
                .environmentObject(dependencies)
                .preferredColorScheme(.dark)
                .task {
                    // SyncEngine automatically handles periodic syncs via state machine
                    Logger.info("[App] SyncEngine initialized")
                }
                .onOpenURL { url in
                    // Handle deep links from URL schemes (e.g., OAuth)
                    Logger.info("[App] Deep link received via URL (SwiftUI): \(url.absoluteString)")
                    Task {
                        do {
                            try await AuthService.shared.handleAuthCallback(url: url)
                            appState.isAuthenticated = AuthService.shared.isAuthenticated
                            appState.currentUser = AuthService.shared.currentUser
                        } catch {
                            Logger.error("[App] Error handling deep link from URL: \(error.localizedDescription)")
                        }
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

    /// Prevents generatePersonalizedCarousels from firing more than once per AppState lifetime.
    /// Starts false; set to true after the first carousel generation completes.
    private(set) var carouselsGeneratedThisLaunch = false

    init(authService: AuthService = .shared) {
        self.authService = authService

        // INSTANT LAUNCH (Phase 4): Load cached state synchronously
        self.isAuthenticated = authService.isAuthenticated
        self.currentUser = authService.currentUser

        // Check if we have cached content for instant display
        let hasCachedContent = loadCachedContentSync()
        if hasCachedContent {
            // Show UI immediately with cached content
            self.isPreloading = false
            Logger.info("[AppState] Instant launch - showing cached content")
        }

        Logger.info("[AppState] Initialized with auth state: authenticated=\(isAuthenticated), user=\(currentUser?.email ?? "nil")")

        // Background initialization (non-blocking)
        Task(priority: .userInitiated) {
            await checkForRequiredUpdate()
            await checkAuthState()

            // CRITICAL: Sync user data from Supabase on every app launch
            await performFullSyncOnLaunch()

            // Only run full preload if we didn't have cached content
            if !hasCachedContent {
                await preloadContent()
            } else {
                // Still run background refresh, but don't block UI
                await refreshContentInBackground()
            }

            await RevenueCatService.shared.refreshOfferings()

            // Check and execute daily prefetch for PRO users
            await DailyContentPrefetchService.shared.checkAndExecuteDailyPrefetch()

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
        Logger.info("[AppState] Updated auth state: authenticated=\(isAuthenticated), user=\(currentUser?.email ?? "nil")")
    }

    /// Perform full sync from Supabase on app launch
    /// This ensures data persists across days and devices
    private func performFullSyncOnLaunch() async {
        guard isAuthenticated, let userId = currentUser?.id else {
            Logger.info("[AppState] Skipping sync - not authenticated")
            return
        }

        Logger.info("[AppState] Performing full sync on app launch...")

        // Check onboarding state from profile first
        await checkOnboardingFromProfile()

        // Sync gamification state first (XP, level, streak, badges)
        await GamificationService.shared.loadUserState(userId: userId)

        // Sync lists from Supabase
        await ListManager.shared.syncListsForAuthenticatedUser()

        // Unblock any PGRST205-stuck operations from previous sessions before pushing
        SyncEngine.shared.unblockAndRetryBlockedOperations()

        // Process any pending outbox operations
        await SyncEngine.shared.pushPendingChanges()

        Logger.info("[AppState] Full sync completed on app launch")
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
            Logger.info("[AppState] Skipping foreground sync - synced recently")
            return
        }

        UserDefaults.standard.set(now, forKey: lastSyncKey)
        Logger.info("[AppState] Performing sync on foreground resume...")

        // Sync gamification state (may have changed on another device)
        await GamificationService.shared.loadUserState(userId: userId)

        // Sync lists
        await ListManager.shared.syncListsForAuthenticatedUser()

        // Process pending outbox
        await SyncEngine.shared.pushPendingChanges()

        Logger.info("[AppState] Foreground sync completed")
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
                    Logger.warning("[AppState] Failed to sync onboarding state: \(error)")
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
                Logger.info("[AppState] Onboarding already completed on another device")
            }
        } catch {
            Logger.warning("[AppState] Failed to check onboarding from profile: \(error)")
        }
    }

    private func checkForRequiredUpdate() async {
        updateRequirement = await UpdateCheckService.shared.checkForRequiredUpdate()
    }

    // MARK: - Instant Launch (Phase 4)

    /// Synchronously check if we have valid cached content for instant display
    /// This runs on init() before any async work
    private func loadCachedContentSync() -> Bool {
        let hasCache = SQLiteService.shared.hasCachedPersonalizedContent()
        let hasInitialData = UserDefaults.standard.bool(forKey: "initialDataPopulated")
        return hasCache || hasInitialData
    }

    /// Background refresh that doesn't block UI
    /// Called when we already have cached content
    private func refreshContentInBackground() async {
        // Run database migrations if needed
        await DatabaseMigrationManager.shared.runMigrations()

        // Initialize app coordinator (background)
        await dataCoordinator.initializeApp()

        // Refresh discovery content in background
        Logger.info("[AppState] Refreshing discovery content in background...")
        do {
            try await DiscoveryCacheService.shared.refreshContent()
        } catch {
            Logger.error("[AppState] Failed to refresh discovery content: \(error.localizedDescription)")
        }

        // Phase 4: Preload images for instant display
        await preloadDiscoveryImages()

        // Pre-warm personalization cache (background, low priority)
        Task(priority: .utility) { [self] in
            guard !self.carouselsGeneratedThisLaunch else { return }
            self.carouselsGeneratedThisLaunch = true
            let profile = await UserPreferenceManager.shared.aggregatePreferences()
            do {
                _ = try await DiscoveryPersonalizationService.shared.generatePersonalizedCarousels(
                    userProfile: profile,
                    forceRefresh: false
                )
            } catch {
                Logger.error("[AppState] Failed to generate personalized carousels: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Image Preloading (Phase 4)

    /// Preload poster images for discovery content
    /// This ensures images are cached for instant display when user scrolls
    private func preloadDiscoveryImages() async {
        // Check user's prefetch preference
        let prefetchOption = ImageCacheService.shared.getCurrentImagePrefetchOption()
        guard await ImageCacheService.shared.shouldPrefetchImages(preference: prefetchOption) else {
            Logger.info("[AppState] Skipping image preload - user preference or network")
            return
        }

        Logger.info("[AppState] Preloading discovery images...")

        // Collect poster URLs from cached content
        var posterURLs: [String] = []

        // From cached clips (thumbnails)
        let clipThumbnails = ContentCacheManager.shared.cachedClips.prefix(10).compactMap { clip -> String? in
            guard let thumbnail = clip.thumbnailURL, !thumbnail.isEmpty else { return nil }
            return thumbnail
        }
        posterURLs.append(contentsOf: clipThumbnails)

        guard !posterURLs.isEmpty else {
            Logger.info("[AppState] No images to preload")
            return
        }

        Logger.info("[AppState] Preloading \(posterURLs.count) images...")
        await ImageCacheService.shared.prefetchImages(posterURLs, onWiFiOnly: prefetchOption == .wifiOnly)
        Logger.info("[AppState] Image preload complete")
    }
    
    private func preloadContent() async {
        isPreloading = true

        // Run unified database migrations (Phase 4: performance indexes, etc.)
        await DatabaseMigrationManager.shared.runMigrations()

        // Check if initial data migration is needed (legacy one-time migration)
        if !UserDefaults.standard.bool(forKey: "initialDataPopulated") {
            Logger.info("[App] First launch detected - migrating data from Supabase to SQLite...")
            await DatabaseMigrationService.shared.migrateInitialData()
        }
        
        // Sync new content from Supabase (incremental sync)
        Logger.info("[App] Syncing new content from Supabase...")
        await SyncEngine.shared.pullFromRemote()
        
        // Optimized parallel preload: Discovery content + 5 initial clips
        // Then background task for 20 more clips
        Logger.info("[App] Starting optimized preload (parallel tasks)...")
        await dataCoordinator.initializeApp()
        
        // Ensure discovery content exists (fetch from TMDB if needed)
        await ensureDiscoveryContentExists()

        // Pre-warm the personalized discovery cache so the Discovery tab loads instantly
        guard !carouselsGeneratedThisLaunch else { return }
        carouselsGeneratedThisLaunch = true
        Logger.info("[App] Pre-warming Discovery personalization cache...")
        let profile = await UserPreferenceManager.shared.aggregatePreferences()
        do {
            // We call this to trigger the cache-miss logic (API fetch + DB cache) if needed.
            // When DiscoveryViewModel calls this later, it will hit the DB cache instantly.
            _ = try await DiscoveryPersonalizationService.shared.generatePersonalizedCarousels(
                userProfile: profile,
                forceRefresh: false
            )
            Logger.info("[App] Discovery personalization pre-warmed successfully")
        } catch {
            Logger.warning("[App] Failed to pre-warm Discovery personalization: \(error)")
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
                Logger.info("[App] Discovery content exists: \(totalContent) items")
            } else {
                Logger.warning("[App] Discovery cache is empty - fetching fresh from TMDB...")
                // Cache is empty, force refresh from TMDB
                try await DiscoveryCacheService.shared.refreshContent()
                Logger.info("[App] Discovery content populated from TMDB")
            }
        } catch {
            Logger.warning("[App] Failed to load discovery content: \(error)")
        }
    }
}
