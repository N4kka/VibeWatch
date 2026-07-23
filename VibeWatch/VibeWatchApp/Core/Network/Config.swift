import Foundation

struct Config {
    // Secrets are sourced from Info.plist (backed by Secrets.xcconfig).
    static let tmdbAPIKey = string(for: "TMDB_API_KEY")
    static let supabaseURL = string(for: "SUPABASE_URL")
    static let supabaseAnonKey = string(for: "SUPABASE_ANON_KEY")
    static let revenueCatAPIKey = string(for: "REVENUECAT_API_KEY")
    static let posthogApiKey = string(for: "POSTHOG_API_KEY")
    static let posthogHost = string(for: "POSTHOG_HOST")
    static let updateConfigURL = string(for: "UPDATE_CONFIG_URL")
    static let appStoreURL = string(for: "APP_STORE_URL")
    // YOUTUBE_API_KEY no longer ships in the bundle either: YouTube goes through the
    // `youtube-search` Edge Function, which holds the key server-side (audit DEP-004).
    // RAPIDAPI_KEY no longer ships in the bundle: streaming availability goes through the
    // `watch-providers` Edge Function, which holds the key server-side (audit DEP-005).
}

private extension Config {
    static func string(for key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        var normalized = raw.replacingOccurrences(of: "\\/", with: "/")
        if normalized.hasPrefix("https:/") && !normalized.hasPrefix("https://") {
            normalized = normalized.replacingOccurrences(of: "https:/", with: "https://")
        }
        if normalized.hasPrefix("http:/") && !normalized.hasPrefix("http://") {
            normalized = normalized.replacingOccurrences(of: "http:/", with: "http://")
        }
        return normalized
    }
}
