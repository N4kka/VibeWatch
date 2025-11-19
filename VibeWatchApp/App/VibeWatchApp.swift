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
        
        // Optimized parallel preload: Discovery content + 5 initial clips
        // Then background task for 20 more clips
        print("🚀 Starting optimized preload (parallel tasks)...")
        await dataCoordinator.initializeApp()
        
        isPreloading = false
    }
}
