import Foundation

@MainActor
class ContentCacheManager: ObservableObject {
    static let shared = ContentCacheManager()

    // Made internal so ClipsRepository can access it
    var cachedClips: [Clip] = []
    @Published var isPreloadingClips = false

    private let db = SQLiteService.shared
    private let clipsService = ClipsService.shared

    // SQLite app_metadata keys
    private let lastUpdateDateKey = "last_discovery_update"
    private let cachedMoviesKey = "cached_discovery_movies"
    private let cachedTVShowsKey = "cached_discovery_tvshows"
    private let cachedClipsKey = "cached_clips"

    // Legacy UserDefaults keys (for migration only)
    private let legacyLastUpdateKey = "lastDiscoveryUpdateDate"
    private let legacyCachedMoviesKey = "cachedDiscoveryMovies"
    private let legacyCachedTVShowsKey = "cachedDiscoveryTVShows"
    private let legacyCachedClipsKey = "cachedClips"

    private init() {
        Task {
            await migrateFromUserDefaultsIfNeeded()
            await loadCachedClips()
        }
    }
    
    // MARK: - Daily Discovery Content

    func shouldUpdateDiscoveryContent() -> Bool {
        // Check in-memory first (sync for callers that need immediate answer)
        guard let lastUpdate = lastUpdateDate else { return true }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lastUpdateDay = calendar.startOfDay(for: lastUpdate)
        return today > lastUpdateDay
    }

    /// In-memory cached last update date (loaded from SQLite at init)
    private var lastUpdateDate: Date?
    private var inMemoryMovies: [Movie]?
    private var inMemoryTVShows: [Movie]?

    func getCachedDiscoveryMovies() -> [Movie]? {
        guard !shouldUpdateDiscoveryContent() else { return nil }
        return inMemoryMovies
    }

    func getCachedDiscoveryTVShows() -> [Movie]? {
        guard !shouldUpdateDiscoveryContent() else { return nil }
        return inMemoryTVShows
    }

    func cacheDiscoveryContent(movies: [Movie], tvShows: [Movie]) {
        let shuffledMovies = movies.shuffled()
        let shuffledTVShows = tvShows.shuffled()

        inMemoryMovies = shuffledMovies
        inMemoryTVShows = shuffledTVShows
        lastUpdateDate = Date()

        Task {
            await saveMetadata(key: cachedMoviesKey, json: shuffledMovies)
            await saveMetadata(key: cachedTVShowsKey, json: shuffledTVShows)
            await saveMetadataText(key: lastUpdateDateKey, value: ISO8601DateFormatter().string(from: Date()))
        }
    }
    
    // MARK: - Shared Preload Logic (The "One Source of Truth")

    /// Orchestrates the main app launch preload:
    /// 1. Fetches Trending Movies (used by BOTH Discovery & Clips)
    /// 2. Picks top 5 movies and preloads clips in parallel
    /// 3. Caches everything
    func performSmartPreload() async {
        Logger.info("[ContentCache] Starting unified smart preload")
        let startTime = Date()

        do {
            // Step 1: Fetch Trending Movies (Source of Truth)
            let moviesResponse = try await TMDBService.shared.getTrendingMovies(timeWindow: .week, page: 1)
            let movies = moviesResponse.results

            // Step 2: Cache for Discovery View in SQLite
            inMemoryMovies = movies
            lastUpdateDate = Date()
            await saveMetadata(key: cachedMoviesKey, json: movies)
            await saveMetadataText(key: lastUpdateDateKey, value: ISO8601DateFormatter().string(from: Date()))
            Logger.debug("[ContentCache] Cached \(movies.count) trending movies for Discovery")

            // Step 3: Preload 5 Clips from these SAME movies (Parallel)
            let preloadedClips = await QuickClipsService.shared.preloadClips(from: movies, count: 5)
            self.cachedClips = preloadedClips

            // Persist clips backup to SQLite
            await saveMetadata(key: cachedClipsKey, json: preloadedClips)

            let duration = Date().timeIntervalSince(startTime)
            Logger.info("[ContentCache] Preload complete in \(String(format: "%.3f", duration))s")

        } catch {
            Logger.error("[ContentCache] Preload failed: \(error.localizedDescription)")
        }

        isPreloadingClips = false
    }

    // MARK: - Clips Pre-loading (Legacy/Fallback)
    
    func preloadClips() async {
        await performSmartPreload()
    }
    
    func clearAllCaches() {
        cachedClips = []
        inMemoryMovies = nil
        inMemoryTVShows = nil
        lastUpdateDate = nil

        Task {
            await deleteMetadata(key: lastUpdateDateKey)
            await deleteMetadata(key: cachedMoviesKey)
            await deleteMetadata(key: cachedTVShowsKey)
            await deleteMetadata(key: cachedClipsKey)
        }
        Logger.debug("[ContentCache] Cleared all caches")
    }

    private func loadCachedClips() async {
        // Load clips from SQLite
        if let clips: [Clip] = await loadMetadata(key: cachedClipsKey) {
            cachedClips = clips
            Logger.debug("[ContentCache] Loaded \(clips.count) cached clips from SQLite")
        }

        // Load discovery content for sync access
        if let movies: [Movie] = await loadMetadata(key: cachedMoviesKey) {
            inMemoryMovies = movies
        }
        if let tvShows: [Movie] = await loadMetadata(key: cachedTVShowsKey) {
            inMemoryTVShows = tvShows
        }
        if let dateStr = await loadMetadataText(key: lastUpdateDateKey) {
            lastUpdateDate = ISO8601DateFormatter().date(from: dateStr)
        }
    }

    func clearClipsCache() {
        cachedClips = []
        Task { await deleteMetadata(key: cachedClipsKey) }
    }

    // MARK: - SQLite Helpers (app_metadata table)

    private func saveMetadata<T: Encodable>(key: String, json value: T) async {
        do {
            guard let data = try? JSONEncoder().encode(value),
                  let jsonStr = String(data: data, encoding: .utf8) else { return }
            _ = try await db.queryRaw(
                "REPLACE INTO app_metadata (key_name, value_json, updated_at) VALUES (?, ?, datetime('now'))",
                parameters: [key, jsonStr]
            )
        } catch {
            Logger.error("[ContentCache] Failed to save metadata '\(key)': \(error)")
        }
    }

    private func saveMetadataText(key: String, value: String) async {
        do {
            _ = try await db.queryRaw(
                "REPLACE INTO app_metadata (key_name, value_text, updated_at) VALUES (?, ?, datetime('now'))",
                parameters: [key, value]
            )
        } catch {
            Logger.error("[ContentCache] Failed to save metadata '\(key)': \(error)")
        }
    }

    private func loadMetadata<T: Decodable>(key: String) async -> T? {
        do {
            let rows = try await db.queryRaw(
                "SELECT value_json FROM app_metadata WHERE key_name = ?",
                parameters: [key]
            )
            guard let row = rows.first,
                  let jsonStr = row["value_json"] as? String,
                  let data = jsonStr.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Logger.error("[ContentCache] Failed to load metadata '\(key)': \(error)")
            return nil
        }
    }

    private func loadMetadataText(key: String) async -> String? {
        do {
            let rows = try await db.queryRaw(
                "SELECT value_text FROM app_metadata WHERE key_name = ?",
                parameters: [key]
            )
            return rows.first?["value_text"] as? String
        } catch {
            Logger.error("[ContentCache] Failed to load metadata '\(key)': \(error)")
            return nil
        }
    }

    private func deleteMetadata(key: String) async {
        do {
            _ = try await db.queryRaw(
                "DELETE FROM app_metadata WHERE key_name = ?",
                parameters: [key]
            )
        } catch {
            Logger.error("[ContentCache] Failed to delete metadata '\(key)': \(error)")
        }
    }

    /// One-time migration from UserDefaults to SQLite
    private func migrateFromUserDefaultsIfNeeded() async {
        let ud = UserDefaults.standard
        guard ud.object(forKey: legacyLastUpdateKey) != nil ||
              ud.data(forKey: legacyCachedMoviesKey) != nil else { return }

        // Migrate movies
        if let data = ud.data(forKey: legacyCachedMoviesKey),
           let jsonStr = String(data: data, encoding: .utf8) {
            await saveMetadataRaw(key: cachedMoviesKey, json: jsonStr)
        }

        // Migrate TV shows
        if let data = ud.data(forKey: legacyCachedTVShowsKey),
           let jsonStr = String(data: data, encoding: .utf8) {
            await saveMetadataRaw(key: cachedTVShowsKey, json: jsonStr)
        }

        // Migrate clips
        if let data = ud.data(forKey: legacyCachedClipsKey),
           let jsonStr = String(data: data, encoding: .utf8) {
            await saveMetadataRaw(key: cachedClipsKey, json: jsonStr)
        }

        // Migrate last update date
        if let date = ud.object(forKey: legacyLastUpdateKey) as? Date {
            await saveMetadataText(key: lastUpdateDateKey, value: ISO8601DateFormatter().string(from: date))
        }

        // Remove legacy keys
        ud.removeObject(forKey: legacyLastUpdateKey)
        ud.removeObject(forKey: legacyCachedMoviesKey)
        ud.removeObject(forKey: legacyCachedTVShowsKey)
        ud.removeObject(forKey: legacyCachedClipsKey)
        Logger.info("[ContentCache] Migrated cache data from UserDefaults to SQLite")
    }

    private func saveMetadataRaw(key: String, json: String) async {
        do {
            _ = try await db.queryRaw(
                "REPLACE INTO app_metadata (key_name, value_json, updated_at) VALUES (?, ?, datetime('now'))",
                parameters: [key, json]
            )
        } catch {
            Logger.error("[ContentCache] Failed to save raw metadata '\(key)': \(error)")
        }
    }
}
