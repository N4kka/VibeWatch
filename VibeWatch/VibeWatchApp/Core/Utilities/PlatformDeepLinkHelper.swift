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
        Logger.debug("[PlatformDeepLink] Opening platform: \(provider.providerName) (ID: \(provider.providerId)), JustWatch: \(justWatchLink ?? "nil"), Direct: \(provider.externalLink?.absoluteString ?? "nil"), Title: \(title)")
        
        // 1. Try direct deep link from provider (RapidAPI)
        if let directURL = provider.externalLink {
            Logger.debug("[PlatformDeepLink] Opening direct deep link: \(directURL.absoluteString)")
            UIApplication.shared.open(directURL, options: [:]) { success in
                if !success {
                    Logger.warning("[PlatformDeepLink] Failed to open deep link, trying fallback...")
                    openFallback(provider: provider, justWatchLink: justWatchLink)
                }
            }
            return
        }
        
        // 2. Fallback to JustWatch or Homepage
        openFallback(provider: provider, justWatchLink: justWatchLink)
    }
    
    @MainActor private static func openFallback(provider: Provider, justWatchLink: String?) {
        if let linkString = justWatchLink, let url = URL(string: linkString) {
            Logger.debug("[PlatformDeepLink] Opening TMDB JustWatch page: \(url.absoluteString)")
            UIApplication.shared.open(url, options: [:])
            return
        }

        Logger.warning("[PlatformDeepLink] No JustWatch link available, opening platform homepage...")
        if let fallbackURL = getPlatformHomepage(provider: provider) ?? getPlatformHomepage(byName: provider.providerName) {
            Logger.debug("[PlatformDeepLink] Opening platform homepage: \(fallbackURL.absoluteString)")
            UIApplication.shared.open(fallbackURL, options: [:])
        } else {
            Logger.error("[PlatformDeepLink] No fallback URL available")
        }
    }
    
    /// Get platform homepage as fallback
    static func getPlatformHomepage(provider: Provider) -> URL? {
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

    static func getPlatformHomepage(byName providerName: String) -> URL? {
        let name = providerName.lowercased()
        if name.contains("netflix") { return URL(string: "https://www.netflix.com/") }
        if name.contains("prime") || name.contains("amazon") { return URL(string: "https://www.primevideo.com/") }
        if name.contains("disney") { return URL(string: "https://www.disneyplus.com/") }
        if name.contains("apple tv") || name == "apple tv" { return URL(string: "https://tv.apple.com/") }
        if name.contains("hbo") || name.contains("max") { return URL(string: "https://www.max.com/") }
        if name.contains("paramount") { return URL(string: "https://www.paramountplus.com/") }
        if name.contains("peacock") { return URL(string: "https://www.peacocktv.com/") }
        if name.contains("showtime") { return URL(string: "https://www.showtime.com/") }
        if name.contains("hulu") { return URL(string: "https://www.hulu.com/") }
        if name.contains("pluto") { return URL(string: "https://pluto.tv/") }
        if name.contains("crunchyroll") { return URL(string: "https://www.crunchyroll.com/") }
        if name.contains("google play") { return URL(string: "https://play.google.com/store/movies") }
        if name.contains("youtube") { return URL(string: "https://www.youtube.com/") }
        if name.contains("rakuten") { return URL(string: "https://rakuten.tv/") }
        if name.contains("timvision") { return URL(string: "https://www.timvision.it/") }
        return nil
    }

    static func hasPlatformHomepage(for provider: Provider) -> Bool {
        return getPlatformHomepage(provider: provider) != nil
            || getPlatformHomepage(byName: provider.providerName) != nil
    }
}
