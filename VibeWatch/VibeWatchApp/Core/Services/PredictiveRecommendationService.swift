import Foundation
import SwiftUI

/// Service for generating predictive content recommendations
/// Uses viewing patterns, time of day, and watch history to suggest perfect content
@MainActor
class PredictiveRecommendationService: ObservableObject {
    static let shared = PredictiveRecommendationService()

    @Published var predictions: [PredictiveRecommendation] = []
    @Published var isLoading = false

    // MARK: - Dependencies

    private let sqliteService = SQLiteService.shared
    private let tmdbService = TMDBService.shared
    private let authService = AuthService.shared

    // MARK: - Initialization

    private init() {
        Logger.info("[PredictiveRecommendationService] Initialized")
    }

    // MARK: - Core Prediction

    /// Generate personalized predictions based on current context
    func generatePredictions(userId: String) async -> [PredictiveRecommendation] {
        isLoading = true
        Logger.info("[PredictiveRecommendationService] Generating predictions for user: \(userId)")

        var allPredictions: [PredictiveRecommendation] = []

        // Get current context
        let context = await getCurrentContext(userId: userId)

        // Run all predictors in parallel
        async let timeBasedPreds = predictByTimeOfDay(context: context)
        async let sequencePreds = predictBySequence(context: context)

        let predictions = await timeBasedPreds + sequencePreds

        // Rank by confidence and deduplicate
        allPredictions = predictions
            .sorted { $0.confidence > $1.confidence }
            .uniqued(on: \.movie.id)
            .prefix(5)
            .map { $0 }

        self.predictions = allPredictions
        isLoading = false

        Logger.info("[PredictiveRecommendationService] Generated \(allPredictions.count) predictions")
        return allPredictions
    }

    // MARK: - Individual Predictors

    /// Predict based on user's viewing patterns at current time
    func predictByTimeOfDay(context: PredictionContext) async -> [PredictiveRecommendation] {
        Logger.info("[PredictiveRecommendationService] Running time-of-day prediction for \(context.timeOfDay)")

        // Get user's preferred genres for this time of day
        let query = """
            SELECT
                p.preference_id as genre_id,
                p.preference_name as genre_name,
                p.score,
                COUNT(h.id) as watch_count,
                CAST(strftime('%H', h.watched_at) AS INTEGER) as hour
            FROM unified_user_preferences p
            INNER JOIN user_clip_history h ON h.user_id = p.user_id
            WHERE p.user_id = ?
                AND p.preference_category = 'genre'
                AND h.watched_at IS NOT NULL
            GROUP BY p.preference_id, hour
            ORDER BY watch_count DESC
        """

        guard let rows = try? await sqliteService.queryRaw(query, parameters: [context.userId]) else {
            return []
        }

        // Find genres watched during this time of day
        _ = Calendar.current.component(.hour, from: context.currentTime)
        let timeRange = getHourRange(for: context.timeOfDay)

        var genreScores: [Int: Double] = [:]
        for row in rows {
            guard let genreIdStr = row["genre_id"] as? String,
                  let genreId = Int(genreIdStr),
                  let hour = row["hour"] as? Int,
                  let watchCount = row["watch_count"] as? Int,
                  timeRange.contains(hour) else {
                continue
            }

            genreScores[genreId, default: 0] += Double(watchCount)
        }

        // Get top 2 genres for this time
        let topGenres = genreScores.sorted { $0.value > $1.value }.prefix(2).map { $0.key }

        guard !topGenres.isEmpty else {
            Logger.info("[PredictiveRecommendationService] No time-based patterns found")
            return []
        }

        // Fetch content matching these genres
        var predictions: [PredictiveRecommendation] = []
        for genreId in topGenres {
            do {
                let response = try await tmdbService.discoverMovies(
                    withGenre: genreId,
                    sortBy: "vote_average.desc",
                    page: 1,
                    minRuntime: nil,
                    maxRuntime: nil,
                    minRating: 7.0,
                    maxRating: nil,
                    releaseDateGte: nil,
                    releaseDateLte: nil,
                    country: nil
                )

                let genreName = rows.first(where: { ($0["genre_id"] as? String).flatMap(Int.init) == genreId })?["genre_name"] as? String ?? "this genre"

                for movie in response.results.prefix(2) {
                    predictions.append(PredictiveRecommendation(
                        id: UUID().uuidString,
                        movie: movie,
                        predictionType: .timeOfDay,
                        confidence: 0.85,
                        reason: "You usually watch \(genreName) around \(context.timeOfDay.rawValue)",
                        timing: .now
                    ))
                }
            } catch {
                Logger.error("[PredictiveRecommendationService] Failed to fetch time-based recommendations", error: error)
            }
        }

        return predictions
    }

    /// Predict based on recent watch sequences (director/genre streaks)
    func predictBySequence(context: PredictionContext) async -> [PredictiveRecommendation] {
        Logger.info("[PredictiveRecommendationService] Running sequence prediction")

        guard context.recentActivity.count >= 2 else {
            Logger.info("[PredictiveRecommendationService] Not enough recent activity for sequence detection")
            return []
        }

        var predictions: [PredictiveRecommendation] = []

        // Use top genre from user profile as a "streak" indicator
        if let topGenre = context.userProfile.topGenres.first {
            do {
                let response = try await tmdbService.discoverMovies(
                    withGenre: topGenre.genreId,
                    sortBy: "vote_average.desc",
                    page: 1,
                    minRuntime: nil,
                    maxRuntime: nil,
                    minRating: 7.5,
                    maxRating: nil,
                    releaseDateGte: nil,
                    releaseDateLte: nil,
                    country: nil
                )

                for movie in response.results.prefix(2) {
                    predictions.append(PredictiveRecommendation(
                        id: UUID().uuidString,
                        movie: movie,
                        predictionType: .sequence,
                        confidence: 0.9,
                        reason: "You're on a \(topGenre.genreName) streak! Here's another",
                        timing: .now
                    ))
                }
            } catch {
                Logger.error("[PredictiveRecommendationService] Failed to fetch sequence recommendations", error: error)
            }
        }

        // Get similar to last watched
        if let lastWatched = context.recentActivity.first {
            do {
                let response = try await tmdbService.getSimilarMovies(id: lastWatched.id, page: 1)

                if let nextMovie = response.results.first {
                    predictions.append(PredictiveRecommendation(
                        id: UUID().uuidString,
                        movie: nextMovie,
                        predictionType: .sequence,
                        confidence: 0.8,
                        reason: "After \(lastWatched.title), you'll love this",
                        timing: .now
                    ))
                }
            } catch {
                Logger.error("[PredictiveRecommendationService] Failed to fetch similar movies", error: error)
            }
        }

        return predictions
    }

    // MARK: - Context Analysis

    private func getCurrentContext(userId: String) async -> PredictionContext {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let dayOfWeek = calendar.component(.weekday, from: now)

        // Determine time of day
        let timeOfDay: TimeOfDay
        switch hour {
        case 6..<12:
            timeOfDay = .morning
        case 12..<18:
            timeOfDay = .afternoon
        case 18..<22:
            timeOfDay = .evening
        default:
            timeOfDay = .night
        }

        // Get recent watch history
        let recentActivity = await getRecentActivity(userId: userId)

        // Get user profile
        let userProfile = await getUserProfile(userId: userId)

        return PredictionContext(
            userId: userId,
            currentTime: now,
            dayOfWeek: dayOfWeek,
            timeOfDay: timeOfDay,
            recentActivity: recentActivity,
            userProfile: userProfile
        )
    }

    private func getRecentActivity(userId: String) async -> [MediaSummary] {
        let query = """
            SELECT media_id, media_type, title, watched_at
            FROM user_clip_history
            WHERE user_id = ?
            ORDER BY watched_at DESC
            LIMIT 5
        """

        guard let rows = try? await sqliteService.queryRaw(query, parameters: [userId]) else {
            return []
        }

        return rows.compactMap { row in
            guard let mediaId = row["media_id"] as? Int,
                  let mediaTypeStr = row["media_type"] as? String,
                  let mediaType = MediaType(rawValue: mediaTypeStr) else {
                return nil
            }

            let title = row["title"] as? String ?? ""

            return MediaSummary(
                id: mediaId,
                title: title,
                year: nil,
                mediaType: mediaType
            )
        }
    }

    private func getUserProfile(userId: String) async -> UserProfile {
        // Get top genres
        let query = """
            SELECT preference_id, preference_name, score
            FROM unified_user_preferences
            WHERE user_id = ? AND preference_category = 'genre'
            ORDER BY score DESC
            LIMIT 5
        """

        guard let rows = try? await sqliteService.queryRaw(query, parameters: [userId]) else {
            return UserProfile.empty
        }

        let topGenres = rows.compactMap { row -> GenrePreference? in
            guard let genreIdStr = row["preference_id"] as? String,
                  let genreId = Int(genreIdStr),
                  let genreName = row["preference_name"] as? String,
                  let score = row["score"] as? Double else {
                return nil
            }

            return GenrePreference(genreId: genreId, genreName: genreName, totalScore: score)
        }

        return UserProfile(
            userId: userId,
            topGenres: topGenres,
            topActors: [],
            preferredMoods: [],
            watchPatterns: WatchPattern(),
            contentTypePreference: ContentTypeRatio(movieRatio: 0.5, tvRatio: 0.5),
            recentActivity: RecentActivity()
        )
    }

    private func getHourRange(for timeOfDay: TimeOfDay) -> ClosedRange<Int> {
        switch timeOfDay {
        case .morning:
            return 6...11
        case .afternoon:
            return 12...17
        case .evening:
            return 18...21
        case .night:
            return 0...5 // + 22...23 handled separately
        }
    }

}

// MARK: - Data Models

struct PredictiveRecommendation: Identifiable {
    let id: String
    let movie: Movie
    let predictionType: PredictionType
    let confidence: Double // 0.0-1.0
    let reason: String
    let timing: PredictionTiming
}

enum PredictionType: String {
    case timeOfDay = "time_of_day"
    case sequence = "sequence"
    case trending = "trending"
}

enum PredictionTiming {
    case now
    case soon(Date)
    case scheduled(Date)

    var displayText: String {
        switch self {
        case .now:
            return "Perfect for right now"
        case .soon(let date):
            let formatter = RelativeDateTimeFormatter()
            return "Perfect for \(formatter.localizedString(for: date, relativeTo: Date()))"
        case .scheduled(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE h:mm a"
            return "Perfect for \(formatter.string(from: date))"
        }
    }
}

struct PredictionContext {
    let userId: String
    let currentTime: Date
    let dayOfWeek: Int
    let timeOfDay: TimeOfDay
    let recentActivity: [MediaSummary]
    let userProfile: UserProfile
}

// MARK: - Helper Extensions

extension Array {
    func uniqued<T: Hashable>(on keyPath: KeyPath<Element, T>) -> [Element] {
        var seen = Set<T>()
        return filter { element in
            let key = element[keyPath: keyPath]
            if seen.contains(key) {
                return false
            } else {
                seen.insert(key)
                return true
            }
        }
    }
}
