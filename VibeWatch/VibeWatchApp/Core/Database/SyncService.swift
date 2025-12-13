import Foundation

/// Service to sync data from Supabase to local SQLite
/// Handles incremental sync on app launch
@MainActor
class SyncService: ObservableObject {
    static let shared = SyncService()
    
    @Published var isSyncing = false
    @Published var syncProgress: Double = 0
    @Published var lastSyncDate: Date?
    
    private let db = SQLiteService.shared
    private let supabase = SupabaseService.shared
    
    private init() {
        loadLastSyncDate()
    }
    
    // MARK: - Public API
    
    /// Sync new content since last sync
    /// Called on app launch
    func syncNewContent() async throws {
        guard !isSyncing else {
            print("⚠️ [Sync] Already syncing, skipping")
            return
        }
        
        isSyncing = true
        syncProgress = 0
        defer { isSyncing = false }
        
        print("🔄 [Sync] Starting incremental sync...")
        print("   📅 Last sync: \(lastSyncDate?.formatted() ?? "Never")")
        
        do {
            // Sync clips (most important)
            syncProgress = 0.1
            try await syncNewClips()
            
            // Sync movies/shows
            syncProgress = 0.6
            try await syncNewMovies()
            
            // Update last sync timestamp
            syncProgress = 0.9
            updateLastSyncDate()
            
            syncProgress = 1.0
            print("✅ [Sync] Incremental sync complete!")
            
        } catch {
            print("❌ [Sync] Sync failed: \(error)")
            throw error
        }
    }
    
    /// Force full sync (use for debugging)
    func forceFullSync() async throws {
        print("🔄 [Sync] Starting FULL sync (all data)...")
        
        lastSyncDate = nil
        try await syncNewContent()
    }
    
    // MARK: - Clip Sync
    
    private func syncNewClips() async throws {
        guard let client = supabase.client else {
            print("⚠️ [Sync] Supabase not configured, skipping clip sync")
            return
        }
        
        print("📥 [Sync] Fetching new clips...")
        
        var fetchedCount = 0
        let limit = 1000
        var offset = 0
        
        while true {
            var query = client.from("clips").select().eq("is_active", value: true)
            
            // Incremental sync if we have a date
            if let date = lastSyncDate {
                let dateString = ISO8601DateFormatter().string(from: date)
                query = query.gt("updated_at", value: dateString)
            }
            
            let batch: [SupabaseClip] = try await query
                .order("updated_at", ascending: true)
                .range(from: offset, to: offset + limit - 1)
                .execute()
                .value
            
            if batch.isEmpty { break }
            
            // Convert to dictionary for batch insert
            let records = batch.compactMap { createClipDictionary(from: $0) }
            
            // Perform batch insert
            let success = await db.performBatchInsert(table: "clips", records: records)
            if !success {
                print("❌ [Sync] Failed to batch insert clips")
                // Continue or throw? Throwing is safer to retry later.
                throw AppError.database(NSError(domain: "SyncService", code: 500, userInfo: nil))
            }
            
            fetchedCount += batch.count
            offset += limit
            
            // Report progress (approximate)
            syncProgress = 0.1 + (Double(fetchedCount) / 15000.0) * 0.5
            print("📦 [Sync] Processed \(fetchedCount) clips...")
        }
        
        print("✅ [Sync] Synced total \(fetchedCount) new clips to SQLite")
    }
    
    // MARK: - Movie/Show Sync
    
    private func syncNewMovies() async throws {
        // Movies sync is handled by DiscoveryCacheService
        // which fetches from TMDB and caches in SQLite
        print("📊 [Sync] Movie sync handled by DiscoveryCacheService")
    }
    
    // MARK: - Sync State Management
    
    private func loadLastSyncDate() {
        if let timestamp = UserDefaults.standard.object(forKey: "last_sync_timestamp") as? Date {
            lastSyncDate = timestamp
        }
    }
    
    private func updateLastSyncDate() {
        let now = Date()
        lastSyncDate = now
        UserDefaults.standard.set(now, forKey: "last_sync_timestamp")
        print("✅ [Sync] Updated last sync timestamp: \(now.formatted())")
    }
    
    // MARK: - Helpers
    
    private func createClipDictionary(from clip: SupabaseClip) -> [String: Any] {
        return [
            "id": clip.id,
            "clip_id": clip.clipId,
            "video_id": clip.videoId,
            "title": clip.title,
            "description": clip.description ?? "",
            "video_url": clip.videoUrl,
            "thumbnail_url": clip.thumbnailUrl ?? "",
            "movie_id": clip.movieId as Any,
            "tv_show_id": clip.tvShowId as Any,
            "media_type": clip.mediaType ?? "",
            "genres": jsonString(from: clip.genres) ?? "[]",
            "actors": jsonString(from: clip.actors) ?? "[]",
            "mood": clip.mood ?? "",
            "keywords": jsonString(from: clip.keywords) ?? "[]",
            "likes": clip.likes ?? 0,
            "comments": clip.comments ?? 0,
            "views": clip.views ?? 0,
            "youtube_views": clip.youtubeViews as Any,
            "tmdb_rating": clip.tmdbRating as Any,
            "quality_score": clip.qualityScore as Any,
            "is_active": true,
            "is_premium": clip.isPremium ?? false,
            "created_at": clip.createdAt ?? ISO8601DateFormatter().string(from: Date()),
            "updated_at": clip.updatedAt ?? ISO8601DateFormatter().string(from: Date())
        ]
    }
    
    private func jsonString(from array: [Any]?) -> String? {
        guard let array = array,
              let data = try? JSONSerialization.data(withJSONObject: array),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
