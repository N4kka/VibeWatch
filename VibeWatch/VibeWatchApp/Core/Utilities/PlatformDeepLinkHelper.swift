import Foundation
import UIKit

/// Helper class to handle deep linking to streaming platform apps and websites
class PlatformDeepLinkHelper {
    
    /// Open the streaming platform app or website for a specific movie/TV show
    /// - Parameters:
    ///   - provider: The streaming provider
    ///   - justWatchLink: The JustWatch link from TMDB (shows platform availability)
    ///   - title: The title (for fallback only)
    @MainActor static func openPlatform(provider: Provider, justWatchLink: String?, title: String) {
        print("🔗 [PlatformDeepLink] Opening platform:")
        print("   Provider: \(provider.providerName) (ID: \(provider.providerId))")
        print("   JustWatch Link: \(justWatchLink ?? "nil")")
        print("   Title: \(title)")
        
        // Open TMDB JustWatch page where user can see all platforms and tap the one they want
        if let linkString = justWatchLink, let url = URL(string: linkString) {
            print("   🌐 Opening TMDB JustWatch page: \(url.absoluteString)")
            UIApplication.shared.open(url, options: [:]) { success in
                if success {
                    print("   ✅ Successfully opened TMDB page")
                } else {
                    print("   ❌ Failed to open TMDB link")
                }
            }
        } else {
            // Fallback: Open platform homepage
            print("   ⚠️ No JustWatch link available, opening platform homepage...")
            if let fallbackURL = getPlatformHomepage(provider: provider) {
                print("   🌐 Opening platform homepage: \(fallbackURL.absoluteString)")
                UIApplication.shared.open(fallbackURL, options: [:])
            } else {
                print("   ❌ No fallback URL available")
            }
        }
    }
    
    /// Get platform homepage as fallback
    private static func getPlatformHomepage(provider: Provider) -> URL? {
        let providerId = provider.providerId
        
        switch providerId {
        case 8: return URL(string: "https://www.netflix.com/")
        case 9, 119: return URL(string: "https://www.primevideo.com/")
        case 337: return URL(string: "https://www.disneyplus.com/")
        case 350, 2: return URL(string: "https://tv.apple.com/")
        case 384, 1899: return URL(string: "https://www.max.com/")
        case 531: return URL(string: "https://www.paramountplus.com/")
        case 386: return URL(string: "https://www.peacocktv.com/")
        case 387: return URL(string: "https://www.showtime.com/")
        case 15: return URL(string: "https://www.hulu.com/")
        case 1796: return URL(string: "https://pluto.tv/")
        case 283: return URL(string: "https://www.crunchyroll.com/")
        case 3: return URL(string: "https://play.google.com/store/movies")
        case 10, 192: return URL(string: "https://www.youtube.com/")
        default: return nil
        }
    }
}
