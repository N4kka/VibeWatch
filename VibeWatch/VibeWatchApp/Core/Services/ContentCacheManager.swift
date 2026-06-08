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
    private let cachedClipsKey = "cached_clips"

    // Legacy UserDefaults keys (for migration only)
    private let legacyCachedClipsKey = "cachedClips"

    private init() {
        Task {
            await migrateFromUserDefaultsIfNeeded()
            await loadCachedClips()
        }
    }

    func clearAllCaches() {
        cachedClips = []
        Task {
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
    }

    func clearClipsCache() {
        cachedClips = []
        Task { await deleteMetadata(key: cachedClipsKey) }
    }

    // MARK: - SQLite Helpers (app_metadata table)

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

    /// One-time migration of cached clips from UserDefaults to SQLite
    private func migrateFromUserDefaultsIfNeeded() async {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: legacyCachedClipsKey),
              let jsonStr = String(data: data, encoding: .utf8) else { return }

        await saveMetadataRaw(key: cachedClipsKey, json: jsonStr)
        ud.removeObject(forKey: legacyCachedClipsKey)
        Logger.info("[ContentCache] Migrated cached clips from UserDefaults to SQLite")
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
