import UIKit
import Supabase

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Initialize LocalizationManager early to ensure translations are loaded before UI
        _ = LocalizationManager.shared
        print("✅ LocalizationManager initialized: \(LocalizationManager.shared.currentLanguage.name)")
        
        return true
    }
    
    // Handle URL schemes (for OAuth callbacks)
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        print("📱 Received URL: \(url.absoluteString)")
        
        // Handle Supabase OAuth callback
        if url.scheme == "com.vibewatch.VibeWatchApp" && url.host == "auth" {
            Task {
                do {
                    // Let Supabase handle the callback
                    try await AuthService.shared.client?.auth.session(from: url)
                    print("✅ OAuth callback handled successfully")
                    
                    // Refresh auth state
                    await AuthService.shared.checkAuthState()
                } catch {
                    print("❌ Error handling OAuth callback: \(error.localizedDescription)")
                }
            }
            return true
        }
        
        return false
    }
}
