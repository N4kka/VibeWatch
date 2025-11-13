import SwiftUI

@main
struct VibeWatchApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}

class AppState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    
    init() {
        checkAuthState()
    }
    
    func checkAuthState() {
        // TODO: Check Supabase auth state
    }
}
