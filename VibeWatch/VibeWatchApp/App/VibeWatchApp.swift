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
    
    init() {
        // Per prima cosa, prima di qualunque consumatore: una chiave mancante non si presenta come
        // errore di configurazione ma come sintomo lontano — TMDB 401 e Scopri bianca, oppure
        // RevenueCat "Invalid API Key" due righe piu' sotto. Elencarle qui e' la differenza fra
        // cinque secondi e un pomeriggio.
        //
        // In Release questo non lascia traccia visibile: `Logger` e' interamente dentro
        // `#if DEBUG`. Se un giorno serve accorgersene anche in produzione, il posto giusto e'
        // qui, mandando `problems` a Crashlytics come non-fatal.
        Config.validateAtLaunch()

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
                .preferredColorScheme(.dark)
                .task {
                    // SyncEngine automatically handles periodic syncs via state machine
                    Logger.info("[App] SyncEngine initialized")
                }
                .onOpenURL { url in
                    Logger.info("[App] Deep link received via URL (SwiftUI): \(url.absoluteString)")
                    // SPEC v3 §9.4: gli universal link (https, host nostro) prima dello scheme
                    // OAuth. `handle` risponde false senza effetti se l'URL non è una rotta
                    // nostra, quindi il ramo OAuth vede esattamente ciò che vedeva prima.
                    if appNavigationManager.handle(universalLink: url) { return }
                    // Handle deep links from URL schemes (e.g., OAuth)
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
                // §3.7: "richiesta di conferma al primo accesso". Uno `sheet` e non un
                // `fullScreenCover`: chi rimanda deve poterla chiudere, e la ritrova al prossimo
                // avvio. Una schermata da cui non si esce e' una trappola, e questa app ne ha gia'
                // avuta una.
                .sheet(isPresented: $appState.showUsernameSetup) {
                    UsernameSetupView { appState.showUsernameSetup = false }
                }
        }
    }
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState() // Singleton for global access if needed
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    /// Deprecati: i toast passano dal `ToastCenter` (finestra dedicata, visibile sopra sheet e cover).
    @available(*, deprecated, message: "Usa ToastCenter.shared")
    @Published var showSuccessToast = false
    @available(*, deprecated, message: "Usa ToastCenter.shared")
    @Published var showErrorToast = false
    @available(*, deprecated, message: "Usa ToastCenter.shared")
    @Published var toastMessage = ""
    @Published var isPreloading = true // Track splash state
    @Published var shouldShowSignIn = false // Trigger for redirecting to sign in flow
    @Published var updateRequirement: UpdateRequirement?
    /// §3.7. Vero quando l'utente non ha uno username, oppure ne ha uno che gli abbiamo assegnato
    /// noi col backfill e che non ha mai confermato.
    @Published var showUsernameSetup = false
    
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

        NotificationCenter.default.addObserver(
            forName: .importJobCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleImportCompleted() }
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

        // Sync gamification state first (XP, level, streak, badges)
        await GamificationService.shared.loadUserState(userId: userId)

        // Sync lists from Supabase
        await ListManager.shared.syncListsForAuthenticatedUser()

        // Unblock any PGRST205-stuck operations from previous sessions before pushing
        SyncEngine.shared.unblockAndRetryBlockedOperations()

        // Push + PULL. Questo si chiama "full sync" da sempre ma faceva solo push: lo specchio
        // locale (tracking, liste, eventi) si riempiva soltanto al sink del NetworkMonitor —
        // di fatto una volta per processo, mai su richiesta. Il pull mette il tracking in
        // testa e notifica le view appena quelle tabelle sono dentro.
        await SyncEngine.shared.performFullSync(trigger: .appLaunch)

        // SPEC v3 blocco 7: lo storico di chi usava VibeWatch prima del tracking nuovo vive in
        // UserDefaults e nelle liste, e `watch_events` per lui e' vuota — cioe' la schermata
        // Tracking e' vuota. Va dopo il sync delle liste, che e' una delle sorgenti che legge.
        // Una tantum, con flag in app_metadata: dopo la prima volta costa una SELECT.
        await LegacyTrackingMigration.shared.runIfNeeded(userId: userId)

        // SPEC v3 §3.7. La domanda la fa il server: `username_confirmed_at` nullo significa
        // "assegnato dal backfill e mai visto da chi lo porta". Un flag locale si perderebbe alla
        // reinstallazione e la schermata ricomparirebbe a chi aveva gia' scelto.
        showUsernameSetup = await UsernameSetupViewModel.isNeeded()

        // Person property per segmentare gli utenti per volume di contenuti tracciati.
        // Una volta per lancio, dopo il pull: prima il conteggio sarebbe quello di ieri.
        if let trackedCount = try? await SQLiteService.shared.count(
            "watch_events", where: "deleted_at IS NULL") {
            AnalyticsService.shared.setPersonProperties(["tracked_items_count": trackedCount])
        }

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

        // Push + pull, come al lancio: un altro device (o un import concluso mentre l'app era
        // in background) deve arrivare sullo schermo al rientro, non al prossimo cold start.
        // Il throttle da 2 minuti qui sopra tiene il costo sotto controllo.
        await SyncEngine.shared.performFullSync(trigger: .foregroundResume)

        Logger.info("[AppState] Foreground sync completed")
    }

    /// Chiamata dopo un login riuscito (email, Apple o Google): stesso giro completo del
    /// lancio. Un account appena entrato ha lo specchio locale vuoto — senza questo pull
    /// immediato Tracking e Scopri restavano vuoti per minuti, finché un evento di rete
    /// qualsiasi non faceva ripartire il sync.
    func syncAfterSignIn() {
        Task { await performFullSyncOnLaunch() }
    }

    /// Dopo un import concluso: pull immediato dello specchio locale e caroselli da rifare.
    /// I caroselli di oggi sono stati generati su un profilo che lo storico appena importato
    /// non lo aveva ancora — senza invalidazione resterebbero congelati fino a mezzanotte.
    private func handleImportCompleted() async {
        await SyncEngine.shared.performFullSync(trigger: .manualRefresh)
        await DiscoveryPersonalizationService.shared.invalidateCache(userId: currentUser?.id)
    }

    // P5 (SPEC v3): `checkOnboardingFromProfile()` lived here and pretended to sync the onboarding
    // flag across devices. `profiles` has neither `onboarding_completed` nor
    // `onboarding_completed_at`, so the write always failed into a Logger.warning and the read
    // always returned nil. The real flag is UserDefaults["hasCompletedOnboarding"], per-device.
    // Removed rather than fixed: cross-device onboarding is not a goal, and `profiles` gets
    // reworked in this same spec (§3.6).

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

        // Niente pre-warm dei caroselli qui: la DiscoveryView è il tab 0 e parte comunque al
        // lancio con lo stesso generatore. La seconda passata "di riscaldamento" non dedupava
        // con quella della view (carouselsGeneratedThisLaunch proteggeva solo da se stessa):
        // a cache scaduta erano ~100 richieste TMDB DOPPIE, in gara sullo stesso throttle.
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
