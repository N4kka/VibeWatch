import Foundation

/// Service to migrate data from Supabase to local SQLite
/// Runs once on first app launch
@MainActor
class DatabaseMigrationService {
    static let shared = DatabaseMigrationService()
    
    private let db = SQLiteService.shared
    private let supabase = SupabaseService.shared
    
    private init() {}
    
    /// Migrate all initial data from Supabase to SQLite
    func migrateInitialData() async {
        print("📥 [Migration] Starting initial data migration...")
        
        // Check if already migrated
        if UserDefaults.standard.bool(forKey: "initialDataPopulated") {
            print("✅ [Migration] Already migrated")
            return
        }
        
        do {
            // Migrate clips (this is the most important)
            await migrateClips()
            
            // Migrate discovery cache
            await migrateDiscoveryCache()
            
            // Mark as completed
            UserDefaults.standard.set(true, forKey: "initialDataPopulated")
            UserDefaults.standard.set(Date(), forKey: "initialDataMigratedDate")
            
            print("✅ [Migration] Initial data migration complete!")
            
        } catch {
            print("❌ [Migration] Migration failed: \(error)")
        }
    }
    
    // MARK: - Clip Migration
    
    private func migrateClips() async {
        print("📥 [Migration] Migrating clips from Supabase...")
        
        guard let client = supabase.client else {
            print("⚠️ [Migration] Supabase not configured, skipping clips migration")
            return
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
            
            print("📦 [Migration] Fetched \(clips.count) clips from Supabase")
            
            // Insert into local SQLite in batches
            var insertedCount = 0
            let batchSize = 100
            
            for batch in clips.chunked(into: batchSize) {
                try await db.transaction {
                    for clip in batch {
                        let values: [String: Any] = [
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
                        insertedCount += 1
                    }
                }
                
                print("📦 [Migration] Inserted \(insertedCount)/\(clips.count) clips")
            }
            
            print("✅ [Migration] Successfully migrated \(insertedCount) clips to local SQLite")
            
        } catch {
            print("❌ [Migration] Failed to migrate clips: \(error)")
        }
    }
    
    // MARK: - Discovery Cache Migration
    
    private func migrateDiscoveryCache() async {
        print("📥 [Migration] Migrating discovery cache from Supabase...")
        
        guard let client = supabase.client else {
            print("⚠️ [Migration] Supabase not configured, skipping discovery cache migration")
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
            
            print("📦 [Migration] Fetched \(cacheItems.count) discovery cache items")
            
            // Insert into local SQLite
            for item in cacheItems {
                let values: [String: Any] = [
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
            
            print("✅ [Migration] Successfully migrated \(cacheItems.count) discovery cache items")
            
        } catch {
            print("❌ [Migration] Failed to migrate discovery cache: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func jsonString(from array: [Any]?) -> String? {
        guard let array = array else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: array),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

// MARK: - Models

struct SupabaseClip: Codable {
    let id: String
    let clipId: String
    let videoId: String
    let title: String
    let description: String?
    let videoUrl: String
    let thumbnailUrl: String?
    let movieId: Int?
    let tvShowId: Int?
    let mediaType: String?
    let genres: [String]?
    let actors: [String]?
    let mood: String?
    let keywords: [String]?
    let likes: Int?
    let comments: Int?
    let views: Int?
    let youtubeViews: Int?
    let tmdbRating: Double?
    let qualityScore: Double?
    let isPremium: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id, title, description, genres, actors, mood, keywords
        case likes, comments, views
        case clipId = "clip_id"
        case videoId = "video_id"
        case videoUrl = "video_url"
        case thumbnailUrl = "thumbnail_url"
        case movieId = "movie_id"
        case tvShowId = "tv_show_id"
        case mediaType = "media_type"
        case youtubeViews = "youtube_views"
        case tmdbRating = "tmdb_rating"
        case qualityScore = "quality_score"
        case isPremium = "is_premium"
    }
}

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

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
