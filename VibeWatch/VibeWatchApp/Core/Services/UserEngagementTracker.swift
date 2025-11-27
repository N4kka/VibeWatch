import Foundation
import SwiftUI

class UserEngagementTracker: ObservableObject {
    static let shared = UserEngagementTracker()
    
    // Watch time tracking
    private var watchHistory: [String: ClipEngagement] = [:] // clipId -> engagement
    
    // Preference scores
    private var genreScores: [Int: Double] = [:] // genreId -> score
    private var actorScores: [Int: Double] = [:] // actorId -> score
    private var movieScores: [Int: Double] = [:] // movieId -> score
    
    // Session tracking
    var currentStreak: Int = 0
    var isInHotStreak: Bool = false
    
    private let userDefaults = UserDefaults.standard
    private let engagementKey = "userEngagementData"
    private let genreScoresKey = "genreScores"
    private let movieScoresKey = "movieScores"
    
    private init() {
        loadEngagementData()
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
                print("🔥 User in HOT STREAK! Boosting engagement content...")
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
        
        print("✅ List addition tracked: +10 genre points, +15 movie points")
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
    
    // MARK: - Persistence
    
    private func saveEngagementData() {
        // Save genre scores
        if let genreData = try? JSONEncoder().encode(genreScores) {
            userDefaults.set(genreData, forKey: genreScoresKey)
        }
        
        // Save movie scores
        if let movieData = try? JSONEncoder().encode(movieScores) {
            userDefaults.set(movieData, forKey: movieScoresKey)
        }
    }
    
    private func loadEngagementData() {
        // Load genre scores
        if let genreData = userDefaults.data(forKey: genreScoresKey),
           let scores = try? JSONDecoder().decode([Int: Double].self, from: genreData) {
            genreScores = scores
        }
        
        // Load movie scores
        if let movieData = userDefaults.data(forKey: movieScoresKey),
           let scores = try? JSONDecoder().decode([Int: Double].self, from: movieData) {
            movieScores = scores
        }
        
        print("✅ Loaded user preferences: \(genreScores.count) genres, \(movieScores.count) movies")
    }
    
    func clearAllData() {
        watchHistory.removeAll()
        genreScores.removeAll()
        actorScores.removeAll()
        movieScores.removeAll()
        currentStreak = 0
        isInHotStreak = false
        
        userDefaults.removeObject(forKey: genreScoresKey)
        userDefaults.removeObject(forKey: movieScoresKey)
        userDefaults.removeObject(forKey: engagementKey)
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
