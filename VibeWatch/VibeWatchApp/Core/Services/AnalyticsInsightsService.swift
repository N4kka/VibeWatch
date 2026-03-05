import Foundation
import SwiftUI

/// Service for generating user analytics and insights
/// Aggregates watch history, preferences, and interaction data to provide meaningful statistics
@MainActor
class AnalyticsInsightsService: ObservableObject {
    static let shared = AnalyticsInsightsService()

    @Published var userStats: UserStatistics?
    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Dependencies

    private let sqliteService = SQLiteService.shared
    private let authService = AuthService.shared

    // MARK: - Initialization

    private init() {
        Logger.info("[AnalyticsInsightsService] Initialized")
    }

    // MARK: - Public API

    /// Generate complete user statistics for the given timeframe
    func generateUserStatistics(userId: String, timeframe: Timeframe = .allTime) async -> UserStatistics? {
        isLoading = true
        error = nil

        Logger.info("[AnalyticsInsightsService] Generating statistics for user: \(userId), timeframe: \(timeframe)")

        do {
            // Run all calculations in parallel
            async let watchStats = calculateWatchStats(userId: userId, timeframe: timeframe)
            async let genreStats = calculateGenreDistribution(userId: userId, timeframe: timeframe)
            async let viewingPatterns = calculateViewingPatterns(userId: userId)
            async let contentPerformance = calculateContentPerformance(userId: userId, timeframe: timeframe)
            async let moodStats = calculateMoodAnalysis(userId: userId, timeframe: timeframe)
            async let discoveryInsights = calculateDiscoveryInsights(userId: userId, timeframe: timeframe)
            async let milestones = detectMilestones(userId: userId)

            let statistics = UserStatistics(
                watchStats: await watchStats,
                genreDistribution: await genreStats,
                viewingPatterns: await viewingPatterns,
                contentPerformance: await contentPerformance,
                moodAnalysis: await moodStats,
                discoveryInsights: await discoveryInsights,
                milestones: await milestones,
                generatedAt: Date()
            )

            self.userStats = statistics
            isLoading = false

            Logger.info("[AnalyticsInsightsService] ✅ Statistics generated successfully")
            return statistics

        } catch {
            Logger.error("[AnalyticsInsightsService] ❌ Failed to generate statistics", error: error)
            self.error = error.localizedDescription
            isLoading = false
            return nil
        }
    }

    // MARK: - Watch Statistics

    func calculateWatchStats(userId: String, timeframe: Timeframe) async -> WatchStats {
        let since = timeframe.startDate

        // Query movies
        let movieQuery = """
            SELECT
                COUNT(DISTINCT media_id) as count,
                SUM(CASE WHEN watch_duration IS NOT NULL THEN watch_duration ELSE 0 END) as total_time
            FROM user_clip_history
            WHERE user_id = ? AND watched_at >= ? AND media_type = 'movie'
        """

        let movieRows = (try? await sqliteService.queryRaw(movieQuery, parameters: [userId, since.ISO8601Format()])) ?? []
        let totalMovies = movieRows.first?["count"] as? Int ?? 0
        let movieMinutes = movieRows.first?["total_time"] as? Int ?? 0

        // Query episodes
        let episodeQuery = """
            SELECT
                COUNT(*) as count,
                SUM(CASE WHEN watch_duration IS NOT NULL THEN watch_duration ELSE 0 END) as total_time
            FROM user_clip_history
            WHERE user_id = ? AND watched_at >= ? AND media_type = 'tv'
        """

        let episodeRows = (try? await sqliteService.queryRaw(episodeQuery, parameters: [userId, since.ISO8601Format()])) ?? []
        let totalEpisodes = episodeRows.first?["count"] as? Int ?? 0
        let episodeMinutes = episodeRows.first?["total_time"] as? Int ?? 0

        // Calculate session average
        let sessionQuery = """
            SELECT AVG(session_duration) as avg_session
            FROM (
                SELECT SUM(watch_duration) as session_duration
                FROM user_clip_history
                WHERE user_id = ? AND watched_at >= ?
                GROUP BY DATE(watched_at)
            )
        """

        let sessionRows = (try? await sqliteService.queryRaw(sessionQuery, parameters: [userId, since.ISO8601Format()])) ?? []
        let avgSession = sessionRows.first?["avg_session"] as? Int ?? 0

        // Calculate completion rate
        let completionQuery = """
            SELECT AVG(CASE WHEN completion_percentage >= 90 THEN 1.0 ELSE 0.0 END) as completion_rate
            FROM user_clip_history
            WHERE user_id = ? AND watched_at >= ? AND completion_percentage IS NOT NULL
        """

        let completionRows = (try? await sqliteService.queryRaw(completionQuery, parameters: [userId, since.ISO8601Format()])) ?? []
        let completionRate = completionRows.first?["completion_rate"] as? Double ?? 0.0

        // Find longest session
        let longestQuery = """
            SELECT MAX(session_duration) as longest
            FROM (
                SELECT SUM(watch_duration) as session_duration
                FROM user_clip_history
                WHERE user_id = ? AND watched_at >= ?
                GROUP BY DATE(watched_at)
            )
        """

        let longestRows = (try? await sqliteService.queryRaw(longestQuery, parameters: [userId, since.ISO8601Format()])) ?? []
        let longestSession = longestRows.first?["longest"] as? Int ?? 0

        return WatchStats(
            totalMovies: totalMovies,
            totalEpisodes: totalEpisodes,
            totalWatchTimeMinutes: movieMinutes + episodeMinutes,
            averageSessionMinutes: avgSession,
            completionRate: completionRate,
            longestSessionMinutes: longestSession
        )
    }

    // MARK: - Genre Distribution

    func calculateGenreDistribution(userId: String, timeframe: Timeframe) async -> GenreStats {
        let since = timeframe.startDate

        let query = """
            SELECT
                p.preference_id as genre_id,
                p.preference_name as genre_name,
                COUNT(DISTINCT h.media_id) as watch_count,
                SUM(CASE WHEN h.watch_duration IS NOT NULL THEN h.watch_duration ELSE 0 END) as total_minutes
            FROM unified_user_preferences p
            INNER JOIN user_clip_history h ON h.user_id = p.user_id
            WHERE p.user_id = ? AND p.preference_category = 'genre'
                AND h.watched_at >= ?
            GROUP BY p.preference_id, p.preference_name
            ORDER BY watch_count DESC
        """

        let rows = (try? await sqliteService.queryRaw(query, parameters: [userId, since.ISO8601Format()])) ?? []

        let totalCount = rows.reduce(0) { $0 + (($1["watch_count"] as? Int) ?? 0) }

        let distribution: [GenreDistribution] = rows.compactMap { row in
            guard let genreId = Int((row["genre_id"] as? String) ?? ""),
                  let genreName = row["genre_name"] as? String,
                  let count = row["watch_count"] as? Int,
                  let minutes = row["total_minutes"] as? Int else {
                return nil
            }

            let percentage = totalCount > 0 ? Double(count) / Double(totalCount) : 0.0

            return GenreDistribution(
                genreId: genreId,
                genreName: genreName,
                count: count,
                percentage: percentage,
                watchTimeMinutes: minutes
            )
        }

        // Get top genre
        let topGenre = distribution.first ?? GenreDistribution(
            genreId: 0,
            genreName: "No Data",
            count: 0,
            percentage: 0.0,
            watchTimeMinutes: 0
        )

        // Detect emerging genre (genre with biggest growth in last month)
        let emergingGenre = await detectEmergingGenre(userId: userId)

        return GenreStats(
            distribution: distribution,
            topGenre: topGenre,
            emergingGenre: emergingGenre
        )
    }

    private func detectEmergingGenre(userId: String) async -> GenreDistribution? {
        // Compare last month vs previous month
        let lastMonthStart = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        let twoMonthsStart = Calendar.current.date(byAdding: .month, value: -2, to: Date())!

        let query = """
            SELECT
                p.preference_id as genre_id,
                p.preference_name as genre_name,
                SUM(CASE WHEN h.watched_at >= ? THEN 1 ELSE 0 END) as last_month_count,
                SUM(CASE WHEN h.watched_at >= ? AND h.watched_at < ? THEN 1 ELSE 0 END) as prev_month_count
            FROM unified_user_preferences p
            INNER JOIN user_clip_history h ON h.user_id = p.user_id
            WHERE p.user_id = ? AND p.preference_category = 'genre'
                AND h.watched_at >= ?
            GROUP BY p.preference_id, p.preference_name
            HAVING last_month_count > prev_month_count
            ORDER BY (last_month_count - prev_month_count) DESC
            LIMIT 1
        """

        let rows = (try? await sqliteService.queryRaw(query, parameters: [
            lastMonthStart.ISO8601Format(),
            twoMonthsStart.ISO8601Format(),
            lastMonthStart.ISO8601Format(),
            userId,
            twoMonthsStart.ISO8601Format()
        ])) ?? []

        guard let row = rows.first,
              let genreId = Int((row["genre_id"] as? String) ?? ""),
              let genreName = row["genre_name"] as? String,
              let count = row["last_month_count"] as? Int else {
            return nil
        }

        return GenreDistribution(
            genreId: genreId,
            genreName: genreName,
            count: count,
            percentage: 0.0,
            watchTimeMinutes: 0
        )
    }

    // MARK: - Viewing Patterns

    func calculateViewingPatterns(userId: String) async -> ViewingPatterns {
        // Build 7×24 heatmap
        var heatmap = Array(repeating: Array(repeating: 0, count: 24), count: 7)

        let heatmapQuery = """
            SELECT
                CAST(strftime('%w', watched_at) AS INTEGER) as day_of_week,
                CAST(strftime('%H', watched_at) AS INTEGER) as hour,
                SUM(CASE WHEN watch_duration IS NOT NULL THEN watch_duration ELSE 30 END) as total_minutes
            FROM user_clip_history
            WHERE user_id = ?
            GROUP BY day_of_week, hour
        """

        let rows = (try? await sqliteService.queryRaw(heatmapQuery, parameters: [userId])) ?? []

        for row in rows {
            let day = row["day_of_week"] as? Int ?? 0
            let hour = row["hour"] as? Int ?? 0
            let minutes = row["total_minutes"] as? Int ?? 0
            heatmap[day][hour] = minutes
        }

        // Calculate average by day of week
        let dayQuery = """
            SELECT
                CASE CAST(strftime('%w', watched_at) AS INTEGER)
                    WHEN 0 THEN 'Sunday'
                    WHEN 1 THEN 'Monday'
                    WHEN 2 THEN 'Tuesday'
                    WHEN 3 THEN 'Wednesday'
                    WHEN 4 THEN 'Thursday'
                    WHEN 5 THEN 'Friday'
                    WHEN 6 THEN 'Saturday'
                END as day_name,
                AVG(daily_total) as avg_minutes
            FROM (
                SELECT
                    DATE(watched_at) as watch_date,
                    strftime('%w', watched_at) as day_of_week,
                    SUM(CASE WHEN watch_duration IS NOT NULL THEN watch_duration ELSE 30 END) as daily_total
                FROM user_clip_history
                WHERE user_id = ?
                GROUP BY watch_date
            )
            GROUP BY day_of_week
        """

        let dayRows = (try? await sqliteService.queryRaw(dayQuery, parameters: [userId])) ?? []
        var averageByDayOfWeek: [String: Int] = [:]

        for row in dayRows {
            if let dayName = row["day_name"] as? String,
               let avgMinutes = row["avg_minutes"] as? Int {
                averageByDayOfWeek[dayName] = avgMinutes
            }
        }

        // Determine preferred time of day
        let preferredTime = determinePreferredTimeOfDay(heatmap: heatmap)

        // Calculate streaks
        let (currentStreak, longestStreak) = await calculateWatchStreaks(userId: userId)

        return ViewingPatterns(
            heatmap: heatmap,
            averageByDayOfWeek: averageByDayOfWeek,
            preferredTimeOfDay: preferredTime,
            currentStreak: currentStreak,
            longestStreak: longestStreak
        )
    }

    private func determinePreferredTimeOfDay(heatmap: [[Int]]) -> TimeOfDay {
        var totals: [TimeOfDay: Int] = [
            .morning: 0,
            .afternoon: 0,
            .evening: 0,
            .night: 0
        ]

        for day in heatmap {
            totals[.morning]! += day[6...11].reduce(0, +)
            totals[.afternoon]! += day[12...17].reduce(0, +)
            totals[.evening]! += day[18...21].reduce(0, +)
            totals[.night]! += (day[22...23] + day[0...5]).reduce(0, +)
        }

        return totals.max(by: { $0.value < $1.value })?.key ?? .evening
    }

    private func calculateWatchStreaks(userId: String) async -> (current: Int, longest: Int) {
        let query = """
            SELECT DISTINCT DATE(watched_at) as watch_date
            FROM user_clip_history
            WHERE user_id = ?
            ORDER BY watch_date DESC
        """

        let rows = (try? await sqliteService.queryRaw(query, parameters: [userId])) ?? []

        guard !rows.isEmpty else { return (0, 0) }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]

        let dates: [Date] = rows.compactMap { row in
            guard let dateString = row["watch_date"] as? String else { return nil }
            return dateFormatter.date(from: dateString + "T00:00:00Z")
        }

        guard !dates.isEmpty else { return (0, 0) }

        var currentStreak = 1
        var longestStreak = 1
        var tempStreak = 1

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Check if current streak is alive
        if let mostRecent = dates.first,
           calendar.isDate(mostRecent, inSameDayAs: today) ||
           calendar.isDate(mostRecent, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: today)!) {
            // Streak is alive
            for i in 1..<dates.count {
                let daysDiff = calendar.dateComponents([.day], from: dates[i], to: dates[i-1]).day ?? 0
                if daysDiff == 1 {
                    tempStreak += 1
                    longestStreak = max(longestStreak, tempStreak)
                } else {
                    break
                }
            }
            currentStreak = tempStreak
        } else {
            currentStreak = 0
        }

        // Calculate longest streak
        tempStreak = 1
        for i in 1..<dates.count {
            let daysDiff = calendar.dateComponents([.day], from: dates[i], to: dates[i-1]).day ?? 0
            if daysDiff == 1 {
                tempStreak += 1
                longestStreak = max(longestStreak, tempStreak)
            } else {
                tempStreak = 1
            }
        }

        return (currentStreak, longestStreak)
    }

    // MARK: - Content Performance

    func calculateContentPerformance(userId: String, timeframe: Timeframe) async -> ContentPerformance {
        let since = timeframe.startDate

        // Highest rated
        let ratedQuery = """
            SELECT media_id, media_type, COUNT(*) as watch_count
            FROM user_clip_history
            WHERE user_id = ? AND watched_at >= ? AND user_rating >= 4
            GROUP BY media_id, media_type
            ORDER BY watch_count DESC, MAX(watched_at) DESC
            LIMIT 5
        """

        let ratedRows = (try? await sqliteService.queryRaw(ratedQuery, parameters: [userId, since.ISO8601Format()])) ?? []
        let highestRated = ratedRows.compactMap { MediaSummary(from: $0) }

        // Most rewatched
        let rewatchQuery = """
            SELECT media_id, media_type, COUNT(*) as watch_count
            FROM user_clip_history
            WHERE user_id = ? AND watched_at >= ?
            GROUP BY media_id, media_type
            HAVING watch_count > 1
            ORDER BY watch_count DESC
            LIMIT 5
        """

        let rewatchRows = (try? await sqliteService.queryRaw(rewatchQuery, parameters: [userId, since.ISO8601Format()])) ?? []
        let mostRewatched = rewatchRows.compactMap { MediaSummary(from: $0) }

        // Fastest binged (TV shows watched in short time)
        let bingeQuery = """
            SELECT media_id, media_type, COUNT(*) as episode_count,
                   JULIANDAY(MAX(watched_at)) - JULIANDAY(MIN(watched_at)) as days_to_complete
            FROM user_clip_history
            WHERE user_id = ? AND media_type = 'tv' AND watched_at >= ?
            GROUP BY media_id
            HAVING episode_count >= 5
            ORDER BY (episode_count / NULLIF(days_to_complete, 0)) DESC
            LIMIT 5
        """

        let bingeRows = (try? await sqliteService.queryRaw(bingeQuery, parameters: [userId, since.ISO8601Format()])) ?? []
        let fastestBinged = bingeRows.compactMap { MediaSummary(from: $0) }

        // Abandoned content (started but didn't finish)
        let abandonedQuery = """
            SELECT media_id, media_type, AVG(completion_percentage) as avg_completion
            FROM user_clip_history
            WHERE user_id = ? AND watched_at >= ? AND completion_percentage < 50
            GROUP BY media_id, media_type
            ORDER BY COUNT(*) DESC
            LIMIT 5
        """

        let abandonedRows = (try? await sqliteService.queryRaw(abandonedQuery, parameters: [userId, since.ISO8601Format()])) ?? []
        let abandoned = abandonedRows.compactMap { MediaSummary(from: $0) }

        return ContentPerformance(
            highestRated: highestRated,
            mostRewatched: mostRewatched,
            fastestBinged: fastestBinged,
            abandoned: abandoned
        )
    }

    // MARK: - Mood Analysis

    /// Compute mood distribution from user's genre viewing history.
    /// Returns a non-nil MoodAnalysis with an empty moodDistribution when the user
    /// has fewer than 5 history items with genre data (placeholder state).
    private func calculateMoodAnalysis(userId: String, timeframe: Timeframe) async -> MoodAnalysis {
        // Deterministic genre → mood mapping (TMDB genre IDs)
        let genreToMood: [Int: String] = [
            35: "Light", 16: "Light", 10751: "Light", 10402: "Light",
            12: "Adventurous", 14: "Adventurous", 878: "Adventurous", 10752: "Adventurous", 37: "Adventurous",
            28: "Intense", 53: "Intense", 27: "Intense", 80: "Intense",
            18: "Thoughtful", 99: "Thoughtful", 36: "Thoughtful", 9648: "Thoughtful",
            10749: "Romantic", 10770: "Romantic"
        ]

        let since = timeframe.startDate
        let sql = """
            SELECT genre_ids FROM user_clip_history
            WHERE user_id = ? AND watched_at >= ?
              AND genre_ids IS NOT NULL AND genre_ids != ''
        """
        let rows = (try? await sqliteService.queryRaw(sql, parameters: [userId, since.ISO8601Format()])) ?? []

        guard rows.count >= 5 else {
            return MoodAnalysis(moodDistribution: [:], preferredMoodByTime: [:], emotionalJourney: [])
        }

        var moodCounts: [String: Int] = [:]
        for row in rows {
            guard let genreString = row["genre_ids"] as? String else { continue }
            let genreIds = genreString
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            for genreId in genreIds {
                if let mood = genreToMood[genreId] {
                    moodCounts[mood, default: 0] += 1
                }
            }
        }

        return MoodAnalysis(moodDistribution: moodCounts, preferredMoodByTime: [:], emotionalJourney: [])
    }

    // MARK: - Discovery Insights

    func calculateDiscoveryInsights(userId: String, timeframe: Timeframe) async -> DiscoveryInsights {
        let since = timeframe.startDate

        let query = """
            SELECT discovery_source, COUNT(*) as count
            FROM user_discovery_interactions
            WHERE user_id = ? AND interacted_at >= ?
            GROUP BY discovery_source
        """

        let rows = (try? await sqliteService.queryRaw(query, parameters: [userId, since.ISO8601Format()])) ?? []

        var sourceBreakdown: [String: Int] = [:]
        for row in rows {
            if let source = row["discovery_source"] as? String,
               let count = row["count"] as? Int {
                sourceBreakdown[source] = count
            }
        }

        let mostSuccessful = sourceBreakdown.max(by: { $0.value < $1.value })?.key ?? "clips"

        // Calculate carousel click rates
        let carouselQuery = """
            SELECT carousel_id, SUM(clicked) as clicks, COUNT(*) as impressions
            FROM user_discovery_interactions
            WHERE user_id = ? AND interacted_at >= ?
            GROUP BY carousel_id
        """

        let carouselRows = (try? await sqliteService.queryRaw(carouselQuery, parameters: [userId, since.ISO8601Format()])) ?? []

        var carouselClickRates: [String: Double] = [:]
        for row in carouselRows {
            if let carouselId = row["carousel_id"] as? String,
               let clicks = row["clicks"] as? Int,
               let impressions = row["impressions"] as? Int,
               impressions > 0 {
                carouselClickRates[carouselId] = Double(clicks) / Double(impressions)
            }
        }

        return DiscoveryInsights(
            sourceBreakdown: sourceBreakdown,
            mostSuccessfulChannel: mostSuccessful,
            carouselClickRates: carouselClickRates
        )
    }

    // MARK: - Milestones

    func detectMilestones(userId: String) async -> [Milestone] {
        var milestones: [Milestone] = []

        // Watch count milestones
        let countQuery = """
            SELECT COUNT(DISTINCT media_id) as total_count
            FROM user_clip_history
            WHERE user_id = ? AND media_type = 'movie'
        """

        let countRows = (try? await sqliteService.queryRaw(countQuery, parameters: [userId])) ?? []
        if let totalMovies = countRows.first?["total_count"] as? Int {
            let watchMilestones = [10, 50, 100, 250, 500, 1000]
            for milestone in watchMilestones {
                if totalMovies >= milestone {
                    milestones.append(Milestone(
                        id: "watch_count_\(milestone)",
                        type: .watchCount,
                        title: "\(milestone) Movies Watched",
                        description: "You've watched \(totalMovies) movies total!",
                        achievedAt: Date(),
                        icon: "film.fill"
                    ))
                }
            }
            // Return only the highest achieved milestone
            milestones = Array(milestones.suffix(1))
        }

        // Streak milestones
        let (_, longestStreak) = await calculateWatchStreaks(userId: userId)
        let streakMilestones = [7, 14, 30, 60, 100]
        var streakMilestoneList: [Milestone] = []
        for milestone in streakMilestones {
            if longestStreak >= milestone {
                streakMilestoneList.append(Milestone(
                    id: "streak_\(milestone)",
                    type: .streak,
                    title: "\(milestone)-Day Streak",
                    description: "You watched content for \(milestone) days in a row!",
                    achievedAt: Date(),
                    icon: "flame.fill"
                ))
            }
        }
        // Return only the highest streak milestone
        if let highest = streakMilestoneList.last {
            milestones.append(highest)
        }

        // Watch time milestones (in hours)
        let timeQuery = """
            SELECT SUM(CASE WHEN watch_duration IS NOT NULL THEN watch_duration ELSE 0 END) as total_minutes
            FROM user_clip_history
            WHERE user_id = ?
        """

        let timeRows = (try? await sqliteService.queryRaw(timeQuery, parameters: [userId])) ?? []
        if let totalMinutes = timeRows.first?["total_minutes"] as? Int {
            let totalHours = totalMinutes / 60
            let timeMilestones = [10, 50, 100, 500, 1000]
            var timeMilestoneList: [Milestone] = []
            for milestone in timeMilestones {
                if totalHours >= milestone {
                    timeMilestoneList.append(Milestone(
                        id: "watch_time_\(milestone)",
                        type: .watchTime,
                        title: "\(milestone) Hours Watched",
                        description: "You've spent \(totalHours) hours watching content!",
                        achievedAt: Date(),
                        icon: "clock.fill"
                    ))
                }
            }
            // Return only the highest time milestone
            if let highest = timeMilestoneList.last {
                milestones.append(highest)
            }
        }

        return milestones
    }
}

// MARK: - Data Models

struct UserStatistics: Codable {
    let watchStats: WatchStats
    let genreDistribution: GenreStats
    let viewingPatterns: ViewingPatterns
    let contentPerformance: ContentPerformance
    let moodAnalysis: MoodAnalysis?
    let discoveryInsights: DiscoveryInsights
    let milestones: [Milestone]
    let generatedAt: Date
}

struct WatchStats: Codable {
    let totalMovies: Int
    let totalEpisodes: Int
    let totalWatchTimeMinutes: Int
    let averageSessionMinutes: Int
    let completionRate: Double // 0.0-1.0
    let longestSessionMinutes: Int

    var totalWatchTimeHours: Int {
        totalWatchTimeMinutes / 60
    }

    var totalContent: Int {
        totalMovies + totalEpisodes
    }
}

struct GenreStats: Codable {
    let distribution: [GenreDistribution]
    let topGenre: GenreDistribution
    let emergingGenre: GenreDistribution?
}

struct GenreDistribution: Codable, Identifiable {
    var id: Int { genreId }
    let genreId: Int
    let genreName: String
    let count: Int
    let percentage: Double
    let watchTimeMinutes: Int
}

struct ViewingPatterns: Codable {
    let heatmap: [[Int]] // 7 days × 24 hours
    let averageByDayOfWeek: [String: Int]
    let preferredTimeOfDay: TimeOfDay
    let currentStreak: Int
    let longestStreak: Int
}

struct ContentPerformance: Codable {
    let highestRated: [MediaSummary]
    let mostRewatched: [MediaSummary]
    let fastestBinged: [MediaSummary]
    let abandoned: [MediaSummary]
}

struct MoodAnalysis: Codable {
    let moodDistribution: [String: Int]
    let preferredMoodByTime: [String: String]
    let emotionalJourney: [EmotionalPoint]
}

struct EmotionalPoint: Codable {
    let date: Date
    let dominantMood: String
    let intensity: Double
}

struct DiscoveryInsights: Codable {
    let sourceBreakdown: [String: Int]
    let mostSuccessfulChannel: String
    let carouselClickRates: [String: Double]
}

struct Milestone: Codable, Identifiable {
    let id: String
    let type: AnalyticsMilestoneType
    let title: String
    let description: String
    let achievedAt: Date
    let icon: String
}

enum AnalyticsMilestoneType: String, Codable {
    case watchCount = "watch_count"
    case watchTime = "watch_time"
    case genreMastery = "genre_mastery"
    case streak = "streak"
    case completion = "completion"
    case discovery = "discovery"
}

enum Timeframe {
    case allTime
    case thisYear
    case thisMonth
    case lastMonth
    case lastWeek

    var startDate: Date {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .allTime:
            return Date(timeIntervalSince1970: 0)
        case .thisYear:
            return calendar.date(from: calendar.dateComponents([.year], from: now))!
        case .thisMonth:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        case .lastMonth:
            return calendar.date(byAdding: .month, value: -1, to: calendar.date(from: calendar.dateComponents([.year, .month], from: now))!)!
        case .lastWeek:
            return calendar.date(byAdding: .day, value: -7, to: now)!
        }
    }
}

// MARK: - Helper Extensions

extension MediaSummary {
    init?(from row: [String: Any]) {
        guard let mediaId = row["media_id"] as? Int,
              let mediaTypeString = row["media_type"] as? String,
              let mediaType = MediaType(rawValue: mediaTypeString) else {
            return nil
        }

        self.init(
            id: mediaId,
            title: "", // Will be populated from TMDB if needed
            year: nil,
            mediaType: mediaType
        )
    }
}
