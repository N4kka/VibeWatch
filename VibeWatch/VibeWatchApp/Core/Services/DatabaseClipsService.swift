import Foundation
import Supabase

/// Service for fetching clips from local SQLite database (offline-first!)
@MainActor
class DatabaseClipsService {
    static let shared = DatabaseClipsService()
    
    private let db = SQLiteService.shared
    private let supabase = SupabaseService.shared
    private let engagementTracker = UserEngagementTracker.shared
    private let quotaManager = DailyQuotaManager.shared
    
    // Gradual rollout percentages (Day 1-7, then 100% DB)
    private let rolloutSchedule: [Int: Double] = [
        1: 0.3,  // Day 1: 30% from DB
        2: 0.4,  // Day 2: 40% from DB
        3: 0.5,  // Day 3: 50% from DB
        4: 0.6,  // Day 4: 60% from DB
        5: 0.7,  // Day 5: 70% from DB
        6: 0.85, // Day 6: 85% from DB
        7: 1.0   // Day 7: 100% from DB (full transition)
    ]
    
    private init() {}
    
    // MARK: - Main Fetch Function
    
    /// Fetch personalized clips (SQLite-first, offline-capable!)
    func fetchPersonalizedClips(count: Int = 20) async throws -> [Clip] {
        Logger.info("[DatabaseClips] Fetching from local SQLite database")
        
        do {
            let clips = try await fetchFromLocalDatabase(count: count)
            
            // If local DB returns clips, use them
            if !clips.isEmpty {
                Logger.info("[DatabaseClips] Successfully fetched \(clips.count) clips from local SQLite")
                return clips
            } else {
                Logger.warning("[DatabaseClips] Local DB is empty, falling back to YouTube API")
                return try await fetchFromYouTubeAPI(count: count)
            }
        } catch {
            Logger.error("[DatabaseClips] Local DB fetch failed: \(error), falling back to YouTube API", error: error)
            return try await fetchFromYouTubeAPI(count: count)
        }
    }
    
    // MARK: - Local SQLite Fetching
    
    private func fetchFromLocalDatabase(count: Int) async throws -> [Clip] {
        // Get user preferences for personalization
        let topGenres = engagementTracker.getTopGenres(limit: 5)
        let deviceId = getDeviceId()
        
        // Fetch ALL active clips from local SQLite, randomized
        // RANDOMIZE clips on every fetch (app launch) - using SQLite's RANDOM()
        let response: [[String: Any]] = try await db.queryRaw("""
            SELECT * FROM clips
            WHERE is_active = 1 AND deleted_at IS NULL
            ORDER BY RANDOM()
        """)
        
        Logger.debug("[DatabaseClips] Fetched \(response.count) randomized clips from local SQLite")
        
        // Parse rows to Clip objects
        var clips: [Clip] = response.compactMap { mapClip(from: $0) }
        
        // Filter by genres if user has preferences
        if !topGenres.isEmpty {
            let genreNames = Set(topGenres.compactMap { genreIdToName($0) })
            let genreFiltered = clips.filter { clip in
                // Parse genres JSON string
                guard let genresString = response.first(where: { ($0["clip_id"] as? String) == clip.id })?["genres"] as? String,
                      let genresData = genresString.data(using: .utf8),
                      let genres = try? JSONDecoder().decode([String].self, from: genresData) else {
                    return false
                }
                return !Set(genres).isDisjoint(with: genreNames)
            }
            
            // Use filtered clips if we have enough
            if genreFiltered.count >= count {
                clips = genreFiltered
            }
        }
        
        // Filter out already-watched clips
        let watchedClips = await getWatchedClipIdsFromLocal(deviceId: deviceId)
        let unwatchedClips = clips.filter { !watchedClips.contains($0.id) }
        
        // Get liked status in one go
        let likedClipIds = ClipsService.shared.getLikedClipIds()
        
        // Map to final model, setting isLiked status
        let finalClips = unwatchedClips.prefix(count).map { clip -> Clip in
            var mutableClip = clip
            mutableClip.isLiked = likedClipIds.contains(clip.id)
            return mutableClip
        }
        
        Logger.info("[DatabaseClips] Returning \(finalClips.count) personalized clips from local SQLite")
        return finalClips
    }
    
    // MARK: - YouTube API Fallback
    
    private func fetchFromYouTubeAPI(count: Int) async throws -> [Clip] {
        Logger.info("[DatabaseClips] Fetching from YouTube API via ClipsService")
        
        // Use existing ClipsService for YouTube API fetching
        let clipsService = ClipsService.shared
        let clips = try await clipsService.fetchTrendingClips(page: 1, limit: count)
        
        Logger.info("[DatabaseClips] Fetched \(clips.count) clips from YouTube API")
        return clips
    }
    
    // MARK: - Search

    /// Search locally stored clips by title or description, prioritizing direct matches.
    func searchClips(query: String, limit: Int = 20) async throws -> [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        let likeQuery = "%\(trimmed)%"
        let rows: [[String: Any]] = try await db.queryRaw("""
            SELECT * FROM clips
            WHERE is_active = 1
              AND deleted_at IS NULL
              AND (LOWER(title) LIKE LOWER(?) OR LOWER(description) LIKE LOWER(?))
            ORDER BY CASE WHEN LOWER(title) LIKE LOWER(?) THEN 0 ELSE 1 END, RANDOM()
            LIMIT ?
        """, parameters: [likeQuery, likeQuery, likeQuery, limit])
        
        let likedClipIds = ClipsService.shared.getLikedClipIds()
        let clips = rows.compactMap { mapClip(from: $0) }.map { clip -> Clip in
            var mutable = clip
            mutable.isLiked = likedClipIds.contains(clip.id)
            return mutable
        }
        
        Logger.debug("[DatabaseClips] Search for '\(trimmed)' returned \(clips.count) clips")
        return clips
    }
    
    // MARK: - Rollout Logic
    
    private func shouldFetchFromDatabase() -> Bool {
        // Get install date (or use current date if not set)
        let installDate = getInstallDate()
        let daysSinceInstall = Calendar.current.dateComponents([.day], from: installDate, to: Date()).day ?? 1
        
        // After day 7 or on day 7, ALWAYS use DB (100%)
        if daysSinceInstall >= 7 {
            Logger.debug("[DatabaseClips] Day \(daysSinceInstall), Using DB: 100% (full transition)")
            return true
        }
        
        // Get percentage for current day (Days 1-6)
        let dbPercentage = rolloutSchedule[daysSinceInstall] ?? 0.3
        
        // Random decision based on percentage
        let randomValue = Double.random(in: 0...1)
        let useDB = randomValue < dbPercentage
        
        Logger.debug("[DatabaseClips] Day \(daysSinceInstall), DB%: \(Int(dbPercentage * 100))%, Random: \(String(format: "%.2f", randomValue)), Using DB: \(useDB)")
        
        return useDB
    }
    
    // MARK: - Helper Functions
    
    private func getWatchedClipIdsFromLocal(deviceId: String) async -> Set<String> {
        do {
            let rows = try await db.queryRaw("""
                SELECT clip_id FROM user_clip_history
                WHERE device_id = ? AND deleted_at IS NULL
            """, parameters: [deviceId])
            
            return Set(rows.compactMap { $0["clip_id"] as? String })
        } catch {
            Logger.warning("[DatabaseClips] Error fetching watched clips from local DB: \(error.localizedDescription)")
            return []
        }
    }
    
    private func getDeviceId() -> String {
        let key = "deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
    
    private func getInstallDate() -> Date {
        let key = "appInstallDate"
        if let existing = UserDefaults.standard.object(forKey: key) as? Date {
            return existing
        }
        // Set install date to yesterday so day count starts at 1, not 0
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        UserDefaults.standard.set(yesterday, forKey: key)
        return yesterday
    }
    
    private func mapClip(from row: [String: Any]) -> Clip? {
        guard
            let clipId = row["clip_id"] as? String,
            let videoId = row["video_id"] as? String,
            let title = row["title"] as? String,
            let videoUrl = row["video_url"] as? String
        else { return nil }
        
        let movieId = (row["movie_id"] as? Int) ?? (row["movie_id"] as? Int64).map(Int.init)
        let tvShowId = (row["tv_show_id"] as? Int) ?? (row["tv_show_id"] as? Int64).map(Int.init)
        
        let createdAt: Date
        if let timestamp = row["created_at"] as? TimeInterval {
            createdAt = Date(timeIntervalSince1970: timestamp)
        } else {
            createdAt = Date()
        }
        
        let likes = (row["likes"] as? Int) ?? (row["likes"] as? Int64).map(Int.init) ?? 0
        let comments = (row["comments"] as? Int) ?? (row["comments"] as? Int64).map(Int.init) ?? 0
        let segmentIndex = (row["segment_index"] as? Int) ?? (row["segment_index"] as? Int64).map(Int.init)
        let startTime = (row["start_time"] as? Int) ?? (row["start_time"] as? Int64).map(Int.init)
        let isSegment = (row["is_segment"] as? Bool)
            ?? (row["is_segment"] as? Int).map { $0 == 1 }
            ?? false
        
        return Clip(
            id: clipId,
            movieId: movieId,
            tvShowId: tvShowId,
            title: title,
            description: row["description"] as? String ?? "",
            videoURL: videoUrl,
            videoId: videoId,
            thumbnailURL: row["thumbnail_url"] as? String ?? "",
            duration: 0,
            likes: likes,
            comments: comments,
            createdAt: createdAt,
            isLiked: false,
            isSegment: isSegment,
            originalClipId: row["original_clip_id"] as? String,
            segmentIndex: segmentIndex,
            startTime: startTime
        )
    }
    
    private func genreIdToName(_ id: Int) -> String? {
        let genreMap: [Int: String] = [
            28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy",
            80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
            14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
            9648: "Mystery", 10749: "Romance", 878: "Sci-Fi", 10770: "TV Movie",
            53: "Thriller", 10752: "War", 37: "Western"
        ]
        return genreMap[id]
    }
}

// MARK: - Database Models

private struct DatabaseClip: Codable {
    let id: UUID
    let clipId: String
    let videoId: String
    let title: String
    let description: String?
    let videoUrl: String
    let thumbnailUrl: String?
    let movieId: Int?
    let tvShowId: Int?
    let mediaType: String?
    let likes: Int
    let comments: Int
    let genres: [String]?
    
    enum CodingKeys: String, CodingKey {
        case id, title, description, likes, comments, genres
        case clipId = "clip_id"
        case videoId = "video_id"
        case videoUrl = "video_url"
        case thumbnailUrl = "thumbnail_url"
        case movieId = "movie_id"
        case tvShowId = "tv_show_id"
        case mediaType = "media_type"
    }
    
    func toClip() -> Clip {
        Clip(
            id: clipId,
            movieId: movieId,
            tvShowId: tvShowId,
            title: title,
            description: description ?? "",
            videoURL: videoUrl,
            videoId: videoId,
            thumbnailURL: thumbnailUrl ?? "",
            duration: 0,
            likes: likes,
            comments: comments,
            createdAt: Date(), // Use current date for DB clips
            isLiked: false // Will be set by ClipsService
        )
    }
}

private struct WatchedClipRow: Codable {
    let clipId: UUID
    
    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id"
    }
}

private struct ClipIdRow: Codable {
    let clipId: String
    
    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id"
    }
}

enum DatabaseError: Error {
    case supabaseNotConfigured
    case noClipsAvailable
}
