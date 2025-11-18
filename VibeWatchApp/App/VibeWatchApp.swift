import SwiftUI

@main
struct VibeWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var localizationManager = LocalizationManager.shared
    
    init() {
        // Force load localizations before any views are created
        _ = LocalizationManager.shared
    }
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .environmentObject(localizationManager)
                .preferredColorScheme(.dark)
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
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var showSuccessToast = false
    @Published var showErrorToast = false
    @Published var toastMessage = ""
    
    private let authService = AuthService.shared
    private let cacheManager = ContentCacheManager.shared
    
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
        // FORCE CLEAR CACHE - testing new YouTube-only algorithm
        print("🔄 FORCE CLEAR: Clearing clips cache to test YouTube-only algorithm...")
        cacheManager.clearClipsCache()
        
        // Pre-load first 2 clips for instant display when user opens Clips tab
        print("🚀 Pre-loading clips on app launch...")
        await cacheManager.preloadClips()
    }
}
