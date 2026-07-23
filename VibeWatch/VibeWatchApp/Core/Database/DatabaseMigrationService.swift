import Foundation

/// Service to migrate data from Supabase to local SQLite
/// Runs once on first app launch
@MainActor
final class DatabaseMigrationService {
    static let shared = DatabaseMigrationService()
    
    private let db = SQLiteService.shared
    private let supabase = SupabaseService.shared
    
    private init() {}
    
    /// Migrate all initial data from Supabase to SQLite
    func migrateInitialData() async {
        Logger.info("[Migration] Starting initial data migration...")
        
        // Check if already migrated
        if UserDefaults.standard.bool(forKey: "initialDataPopulated") {
            Logger.info("[Migration] Already migrated")
            return
        }
        
        do {
            try await DatabaseUtilities.retryOnFailure(maxAttempts: 3) { @MainActor in
                // Migrate clips (this is the most important). Throws on a real failure — a missing
                // Supabase client or a fetch error — so retryOnFailure retries, and, crucially, the
                // "completed" flag below is NOT written. Before, migrateClips swallowed its own
                // errors and always returned, so the migration marked itself done even when it had
                // imported nothing, and never ran again.
                try await self.migrateClips()

                // Discovery cache is a refillable warm cache, not essential data: it stays
                // best-effort and never blocks completion.
                await self.migrateDiscoveryCache()

                // Mark as completed — reached only when clips actually migrated.
                UserDefaults.standard.set(true, forKey: "initialDataPopulated")
                UserDefaults.standard.set(Date(), forKey: "initialDataMigratedDate")

                Logger.info("[Migration] Initial data migration complete!")
            }
        } catch {
            Logger.error("[Migration] Migration failed after retries, will retry next launch: \(error)")
        }
    }

    enum MigrationError: Error {
        case supabaseNotConfigured
    }
    
    // MARK: - Clip Migration
    
    private func migrateClips() async throws {
        Logger.info("[Migration] Migrating clips from Supabase...")

        guard let client = supabase.client else {
            Logger.warning("[Migration] Supabase not configured — clips migration cannot complete")
            throw MigrationError.supabaseNotConfigured
        }

        do {
            // Fetch all active clips from Supabase
            let clips: [SupabaseClip] = try await client
                .from("clips")
                .select()
                .eq("is_active", value: true)
                .limit(10000) // Get up to 10k clips
                .execute()
                .value
            
            Logger.debug("[Migration] Fetched \(clips.count) clips from Supabase")
            
            // Insert into local SQLite in batches
            var insertedCount = 0
            let batchSize = 100
            
            for batch in clips.chunked(into: batchSize) {
                try await db.transaction {
                    for clip in batch {
                        let values: [String: Any] = await [
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
                            "is_premium": clip.isPremium ?? false
                        ]

                        _ = try await db.insert("clips", values: values)
                    }
                }

                // Reaching here without throwing means the whole batch committed.
                insertedCount += batch.count
                Logger.debug("[Migration] Inserted \(insertedCount)/\(clips.count) clips")
            }
            
            Logger.info("[Migration] Successfully migrated \(insertedCount) clips to local SQLite")

        } catch {
            // Re-raise: a failed clips import must NOT be recorded as a completed migration.
            Logger.error("[Migration] Failed to migrate clips: \(error)")
            throw error
        }
    }
    
    // MARK: - Discovery Cache Migration
    
    private func migrateDiscoveryCache() async {
        Logger.info("[Migration] Migrating discovery cache from Supabase...")
        
        guard let client = supabase.client else {
            Logger.warning("[Migration] Supabase not configured, skipping discovery cache migration")
            return
        }
        
        do {
            // Fetch discovery cache from Supabase
            let cacheItems: [SupabaseDiscoveryCache] = try await client
                .from("discovery_cache")
                .select()
                .gte("expires_at", value: Date())
                .execute()
                .value
            
            Logger.debug("[Migration] Fetched \(cacheItems.count) discovery cache items")
            
            // Insert into local SQLite. This used to go through DatabaseUtilities
            // .executeInTransaction, which never opened a transaction: a failure part-way left the
            // cache half-populated instead of empty.
            try await db.transaction {
                for item in cacheItems {
                    let values: [String: Any] = await [
                        "id": item.id,
                        "content_type": item.contentType,
                        "tmdb_id": item.tmdbId,
                        "title": item.title,
                        "overview": item.overview ?? "",
                        "poster_path": item.posterPath ?? "",
                        "backdrop_path": item.backdropPath ?? "",
                        "vote_average": item.voteAverage as Any,
                        "release_date": item.releaseDate ?? "",
                        "genres": jsonString(from: item.genres) ?? "[]",
                        "cached_at": ISO8601DateFormatter().string(from: item.cachedAt),
                        "expires_at": ISO8601DateFormatter().string(from: item.expiresAt)
                    ]
                    
                    _ = try await db.insert("discovery_cache", values: values)
                }
            }
            
            Logger.info("[Migration] Successfully migrated \(cacheItems.count) discovery cache items")
            
        } catch {
            Logger.error("[Migration] Failed to migrate discovery cache: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    // Generic, strongly-typed, and Sendable-safe JSON array serialization
    private func jsonString<T: Encodable & Sendable>(from array: [T]?) -> String? {
        guard let array = array else { return nil }
        guard let data = try? JSONEncoder().encode(array),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

extension DatabaseMigrationService: @unchecked Sendable {}

// MARK: - Models

struct SupabaseDiscoveryCache: Codable {
    let id: String
    let contentType: String
    let tmdbId: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let releaseDate: String?
    let genres: [Int]?
    let cachedAt: Date
    let expiresAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, title, overview, genres
        case contentType = "content_type"
        case tmdbId = "tmdb_id"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
        case cachedAt = "cached_at"
        case expiresAt = "expires_at"
    }
}
