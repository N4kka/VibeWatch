import SwiftUI

@main
struct VibeWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var localizationManager = LocalizationManager.shared
    @StateObject private var syncWorker = SyncWorker.shared
    @StateObject private var sqliteDB = SQLiteService.shared
    
    init() {
        // Force load localizations before any views are created
        _ = LocalizationManager.shared
        
        // Initialize offline-first database
        print("🗄️ [App] Initializing SQLite database...")
    }
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .environmentObject(localizationManager)
                .environmentObject(syncWorker)
                .preferredColorScheme(.dark)
                .task {
                    // Start background sync worker
                    await syncWorker.startPeriodicSync()
                    print("🔄 [App] Background sync started")
                }
                .onOpenURL { url in
                    // Handle deep links
                    print("📱 Deep link received: \(url.absoluteString)")
                    Task {
                        do {
                            try await AuthService.shared.client?.auth.session(from: url)
                            await AuthService.shared.checkAuthState()
                            appState.isAuthenticated = AuthService.shared.isAuthenticated
                            appState.currentUser = AuthService.shared.currentUser
                        } catch {
                            print("❌ Error handling deep link: \(error.localizedDescription)")
                        }
                    }
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
    
    private let authService = AuthService.shared
    private let dataCoordinator = DataCoordinator.shared
    
    init() {
        Task {
            await checkAuthState()
            await preloadContent()
        }
    }
    
    func checkAuthState() async {
        await authService.checkAuthState()
        self.isAuthenticated = authService.isAuthenticated
        self.currentUser = authService.currentUser
    }
    
    private func preloadContent() async {
        isPreloading = true
        
        // Check if initial data migration is needed
        if !UserDefaults.standard.bool(forKey: "initialDataPopulated") {
            print("📥 [App] First launch detected - migrating data from Supabase to SQLite...")
            await DatabaseMigrationService.shared.migrateInitialData()
        }
        
        // Optimized parallel preload: Discovery content + 5 initial clips
        // Then background task for 20 more clips
        print("🚀 Starting optimized preload (parallel tasks)...")
        await dataCoordinator.initializeApp()
        
        // Ensure discovery content exists (fetch from TMDB if needed)
        await ensureDiscoveryContentExists()
        
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
