import Foundation
import SwiftUI

class UserEngagementTracker: ObservableObject {
    @MainActor static let shared = UserEngagementTracker()

    // Watch time tracking
    private var watchHistory: [String: ClipEngagement] = [:] // clipId -> engagement

    // Preference scores
    private var genreScores: [Int: Double] = [:] // genreId -> score
    private var actorScores: [Int: Double] = [:] // actorId -> score
    private var movieScores: [Int: Double] = [:] // movieId -> score

    // Session tracking
    var currentStreak: Int = 0
    var isInHotStreak: Bool = false

    private let db = SQLiteService.shared
    private let legacyGenreScoresKey = "genreScores"
    private let legacyMovieScoresKey = "movieScores"
    private let legacyEngagementKey = "userEngagementData"

    private init() {
        Task {
            await migrateFromUserDefaultsIfNeeded()
            await loadFromSQLite()
        }
    }
    
    // MARK: - Watch Time Tracking
    
    func startWatchingClip(_ clip: Clip) {
        let engagement = ClipEngagement(
            clipId: clip.id,
            movieId: clip.movieId,
            tvShowId: clip.tvShowId,
            startTime: Date(),
            genreIds: []
        )
        watchHistory[clip.id] = engagement
    }
    
    func updateWatchTime(clipId: String, duration: TimeInterval, totalDuration: TimeInterval) {
        guard var engagement = watchHistory[clipId] else { return }
        
        engagement.watchDuration = duration
        engagement.completionPercentage = totalDuration > 0 ? (duration / totalDuration) : 0
        watchHistory[clipId] = engagement
        
        // Calculate score based on watch time
        let score = calculateEngagementScore(duration: duration, total: totalDuration)
        engagement.engagementScore = score
        
        // Don't process until they leave the clip
    }
    
    func endWatchingClip(clipId: String, genres: [Int] = [], actors: [Int] = []) {
        guard var engagement = watchHistory[clipId] else { return }
        
        engagement.endTime = Date()
        engagement.genreIds = genres
        watchHistory[clipId] = engagement
        
        let score = engagement.engagementScore
        
        // Update preferences based on engagement score
        if score != 0 {
            // Update genre scores
            for genreId in genres {
                let currentScore = genreScores[genreId] ?? 0
                genreScores[genreId] = currentScore + score
            }
            
            // Update actor scores
            for actorId in actors {
                let currentScore = actorScores[actorId] ?? 0
                actorScores[actorId] = currentScore + (score * 0.5) // Actors have 50% weight of genres
            }
            
            // Update movie/TV score
            if let movieId = engagement.movieId {
                let currentScore = movieScores[movieId] ?? 0
                movieScores[movieId] = currentScore + score
            } else if let tvShowId = engagement.tvShowId {
                let currentScore = movieScores[tvShowId] ?? 0
                movieScores[tvShowId] = currentScore + score
            }
            
            // Update streak
            updateStreak(score: score)
        }
        
        // Save to persistence
        saveEngagementData()
    }
    
    private func calculateEngagementScore(duration: TimeInterval, total: TimeInterval) -> Double {
        let percentage = total > 0 ? (duration / total) : 0
        
        switch percentage {
        case 0..<0.1:
            return -1.0 // Skip immediately (dislike)
        case 0.1..<0.25:
            return 0.0 // Not interested
        case 0.25..<0.5:
            return 1.0 // Mild interest
        case 0.5..<0.8:
            return 3.0 // Interested
        case 0.8...1.0:
            return 5.0 // Love it!
        default:
            return 0.0
        }
    }
    
    // MARK: - Hot Streak Detection
    
    private func updateStreak(score: Double) {
        if score >= 3.0 {
            currentStreak += 1
            if currentStreak >= 3 {
                isInHotStreak = true
                Logger.debug("[Engagement] User in hot streak, boosting engagement content")
            }
        } else if score <= 0 {
            currentStreak = 0
            isInHotStreak = false
        }
    }
    
    func resetStreak() {
        currentStreak = 0
        isInHotStreak = false
    }
    
    // MARK: - Save to List Intelligence
    
    func trackListAddition(clip: Clip, listType: String, genres: [Int] = []) {
        // Big boost for adding to list
        for genreId in genres {
            let currentScore = genreScores[genreId] ?? 0
            genreScores[genreId] = currentScore + 10.0
        }
        
        // Boost movie/TV score
        if let movieId = clip.movieId {
            let currentScore = movieScores[movieId] ?? 0
            movieScores[movieId] = currentScore + 15.0
        } else if let tvShowId = clip.tvShowId {
            let currentScore = movieScores[tvShowId] ?? 0
            movieScores[tvShowId] = currentScore + 15.0
        }
        
        Logger.debug("[Engagement] List addition tracked: +10 genre points, +15 movie points")
        saveEngagementData()
    }
    
    // MARK: - Preference Queries
    
    func getTopGenres(limit: Int = 5) -> [Int] {
        let sorted = genreScores.sorted { $0.value > $1.value }
        return Array(sorted.prefix(limit).map { $0.key })
    }
    
    func getGenreScore(_ genreId: Int) -> Double {
        return genreScores[genreId] ?? 0
    }
    
    func getMovieScore(_ movieId: Int) -> Double {
        return movieScores[movieId] ?? 0
    }
    
    func hasAnyPreferences() -> Bool {
        return !genreScores.isEmpty || !movieScores.isEmpty
    }
    
    // MARK: - Persistence (SQLite)

    private func saveEngagementData() {
        Task { await saveToSQLite() }
    }

    private func saveToSQLite() async {
        let userId = await SupabaseService.shared.currentUser?.id ?? "anonymous"
        let deviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") ?? "unknown"

        do {
            // Save genre scores
            for (genreId, score) in genreScores {
                let prefId = "\(userId)_genre_\(genreId)"
                let sql = """
                    REPLACE INTO user_preferences (id, user_id, device_id, preference_type, preference_id, score, updated_at)
                    VALUES (?, ?, ?, 'genre', ?, ?, datetime('now'))
                """
                _ = try await db.queryRaw(sql, parameters: [prefId, userId, deviceId, String(genreId), score])
            }

            // Save movie scores
            for (movieId, score) in movieScores {
                let prefId = "\(userId)_movie_\(movieId)"
                let sql = """
                    REPLACE INTO user_preferences (id, user_id, device_id, preference_type, preference_id, score, updated_at)
                    VALUES (?, ?, ?, 'movie', ?, ?, datetime('now'))
                """
                _ = try await db.queryRaw(sql, parameters: [prefId, userId, deviceId, String(movieId), score])
            }

            // Save actor scores
            for (actorId, score) in actorScores {
                let prefId = "\(userId)_actor_\(actorId)"
                let sql = """
                    REPLACE INTO user_preferences (id, user_id, device_id, preference_type, preference_id, score, updated_at)
                    VALUES (?, ?, ?, 'actor', ?, ?, datetime('now'))
                """
                _ = try await db.queryRaw(sql, parameters: [prefId, userId, deviceId, String(actorId), score])
            }
        } catch {
            Logger.error("[Engagement] Failed to save to SQLite: \(error)")
        }
    }

    private func loadFromSQLite() async {
        let userId = await SupabaseService.shared.currentUser?.id ?? "anonymous"

        do {
            let rows = try await db.queryRaw(
                "SELECT preference_type, preference_id, score FROM user_preferences WHERE user_id = ? AND deleted_at IS NULL",
                parameters: [userId]
            )

            for row in rows {
                guard let type = row["preference_type"] as? String,
                      let idStr = row["preference_id"] as? String,
                      let id = Int(idStr),
                      let score = row["score"] as? Double else { continue }

                switch type {
                case "genre": genreScores[id] = score
                case "movie": movieScores[id] = score
                case "actor": actorScores[id] = score
                default: break
                }
            }

            Logger.debug("[Engagement] Loaded preferences: \(genreScores.count) genres, \(movieScores.count) movies")
        } catch {
            Logger.error("[Engagement] Failed to load from SQLite: \(error)")
        }
    }

    /// One-time migration from UserDefaults to SQLite
    private func migrateFromUserDefaultsIfNeeded() async {
        let ud = UserDefaults.standard
        guard ud.data(forKey: legacyGenreScoresKey) != nil || ud.data(forKey: legacyMovieScoresKey) != nil else { return }

        if let genreData = ud.data(forKey: legacyGenreScoresKey),
           let scores = try? JSONDecoder().decode([Int: Double].self, from: genreData) {
            genreScores = scores
        }
        if let movieData = ud.data(forKey: legacyMovieScoresKey),
           let scores = try? JSONDecoder().decode([Int: Double].self, from: movieData) {
            movieScores = scores
        }

        await saveToSQLite()

        ud.removeObject(forKey: legacyGenreScoresKey)
        ud.removeObject(forKey: legacyMovieScoresKey)
        ud.removeObject(forKey: legacyEngagementKey)
        Logger.info("[Engagement] Migrated engagement data from UserDefaults to SQLite")
    }

    func clearAllData() {
        watchHistory.removeAll()
        genreScores.removeAll()
        actorScores.removeAll()
        movieScores.removeAll()
        currentStreak = 0
        isInHotStreak = false

        Task {
            let userId = await SupabaseService.shared.currentUser?.id ?? "anonymous"
            do {
                _ = try await db.queryRaw(
                    "DELETE FROM user_preferences WHERE user_id = ?",
                    parameters: [userId]
                )
            } catch {
                Logger.error("[Engagement] Failed to clear SQLite data: \(error)")
            }
        }
    }
}

// MARK: - Supporting Models

struct ClipEngagement: Codable {
    let clipId: String
    let movieId: Int?
    let tvShowId: Int?
    var startTime: Date
    var endTime: Date?
    var watchDuration: TimeInterval = 0
    var completionPercentage: Double = 0
    var engagementScore: Double = 0
    var genreIds: [Int]
}
