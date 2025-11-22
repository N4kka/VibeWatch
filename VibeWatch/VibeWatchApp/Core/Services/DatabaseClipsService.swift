import Foundation
import Supabase

/// Service for fetching clips from Supabase database (instead of YouTube API)
@MainActor
class DatabaseClipsService {
    static let shared = DatabaseClipsService()
    
    private let supabase = SupabaseService.shared
    private let engagementTracker = UserEngagementTracker.shared
    private let quotaManager = DailyQuotaManager.shared
    
    // Gradual rollout percentages (Day 1-7)
    private let rolloutSchedule: [Int: Double] = [
        1: 0.3,  // Day 1: 30% from DB
        2: 0.3,  // Day 2: 30% from DB
        3: 0.6,  // Day 3: 60% from DB
        4: 0.6,  // Day 4: 60% from DB
        5: 0.9,  // Day 5: 90% from DB
        6: 0.9,  // Day 6: 90% from DB
        7: 0.9   // Day 7: 90% from DB
    ]
    
    private init() {}
    
    // MARK: - Main Fetch Function
    
    /// Fetch personalized clips (DB-first with gradual rollout)
    func fetchPersonalizedClips(count: Int = 20) async throws -> [Clip] {
        // Determine if we should use DB based on rollout schedule
        let shouldUseDB = shouldFetchFromDatabase()
        
        if shouldUseDB {
            print("📊 [DatabaseClips] Attempting to fetch from Supabase DB")
            
            do {
                let clips = try await fetchFromDatabase(count: count)
                
                // If DB returns clips, use them
                if !clips.isEmpty {
                    print("✅ [DatabaseClips] Successfully fetched \(clips.count) clips from DB")
                    return clips
                } else {
                    print("⚠️ [DatabaseClips] DB is empty, falling back to YouTube API")
                    return try await fetchFromYouTubeAPI(count: count)
                }
            } catch {
                print("❌ [DatabaseClips] DB fetch failed: \(error), falling back to YouTube API")
                return try await fetchFromYouTubeAPI(count: count)
            }
        } else {
            print("🔄 [DatabaseClips] Using YouTube API (rollout schedule)")
            return try await fetchFromYouTubeAPI(count: count)
        }
    }
    
    // MARK: - Database Fetching
    
    private func fetchFromDatabase(count: Int) async throws -> [Clip] {
        guard let client = supabase.client else {
            throw DatabaseError.supabaseNotConfigured
        }
        
        // Get user preferences for personalization
        let topGenres = engagementTracker.getTopGenres(limit: 5)
        let deviceId = getDeviceId()
        
        // Build query - use anon access (no auth required)
        let response: [DatabaseClip]
        do {
            // Simple query first - just get active clips sorted by quality
            response = try await client
                .from("clips")
                .select()
                .eq("is_active", value: true)
                .order("quality_score", ascending: false)
                .limit(count * 2) // Fetch more than needed for filtering
                .execute()
                .value
        } catch {
            print("⚠️ [DatabaseClips] Supabase query failed: \(error)")
            throw error
        }
        
        // Filter by genres in-memory if user has preferences
        var filteredClips = response
        if !topGenres.isEmpty {
            let genreNames = Set(topGenres.compactMap { genreIdToName($0) })
            filteredClips = response.filter { clip in
                guard let clipGenres = clip.genres else { return false }
                return !Set(clipGenres).isDisjoint(with: genreNames)
            }
            // If filtering left us with too few, use all clips
            if filteredClips.count < count {
                filteredClips = response
            }
        }
        
        // Filter out already-watched clips
        let watchedClips = await getWatchedClipIds(deviceId: deviceId)
        let unwatchedClips = filteredClips.filter { !watchedClips.contains($0.clipId) }
        
        // Convert to Clip models and return limited count
        let clips = Array(unwatchedClips.prefix(count)).map { $0.toClip() }
        
        // Record that these clips were served
        await recordServedClips(clips)
        
        print("✅ [DatabaseClips] Fetched \(clips.count) personalized clips from DB")
        return clips
    }
    
    // MARK: - YouTube API Fallback
    
    private func fetchFromYouTubeAPI(count: Int) async throws -> [Clip] {
        print("🎬 [DatabaseClips] Fetching from YouTube API via ClipsService")
        
        // Use existing ClipsService for YouTube API fetching
        let clipsService = ClipsService.shared
        let clips = try await clipsService.fetchTrendingClips(page: 1, limit: count)
        
        print("✅ [DatabaseClips] Fetched \(clips.count) clips from YouTube API")
        return clips
    }
    
    // MARK: - Rollout Logic
    
    private func shouldFetchFromDatabase() -> Bool {
        // Get install date (or use current date if not set)
        let installDate = getInstallDate()
        let daysSinceInstall = Calendar.current.dateComponents([.day], from: installDate, to: Date()).day ?? 1
        
        // After day 7, always use DB (100%)
        if daysSinceInstall > 7 {
            return true
        }
        
        // Get percentage for current day
        let dbPercentage = rolloutSchedule[daysSinceInstall] ?? 0.3
        
        // Random decision based on percentage
        let randomValue = Double.random(in: 0...1)
        let useDB = randomValue < dbPercentage
        
        print("📅 [DatabaseClips] Day \(daysSinceInstall), DB%: \(dbPercentage * 100)%, Using DB: \(useDB)")
        
        return useDB
    }
    
    // MARK: - Helper Functions
    
    private func getWatchedClipIds(deviceId: String) async -> Set<String> {
        guard let client = supabase.client else {
            return []
        }
        
        do {
            let response: [WatchedClipRow] = try await client
                .from("user_clip_history")
                .select("clip_id")
                .eq("device_id", value: deviceId)
                .execute()
                .value
            
            // Get clip_id strings from UUIDs
            let clipUUIDs = response.map { $0.clipId }
            
            // Fetch clip_id strings
            let clipsResponse: [ClipIdRow] = try await client
                .from("clips")
                .select("clip_id")
                .in("id", values: clipUUIDs.map { $0.uuidString })
                .execute()
                .value
            
            return Set(clipsResponse.map { $0.clipId })
            
        } catch {
            print("⚠️ [DatabaseClips] Error fetching watched clips: \(error)")
            return []
        }
    }
    
    private func recordServedClips(_ clips: [Clip]) async {
        // Record served clips in background (non-critical)
        // For now, just log - can implement view tracking later
        print("📊 [DatabaseClips] Served \(clips.count) clips")
        
        // TODO: Implement view tracking when needed
        // Could use client.rpc or direct update queries
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
