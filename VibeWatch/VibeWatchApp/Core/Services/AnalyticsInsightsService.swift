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
            async let moodStats = calculateMoodAnalysis(userId: userId, timeframe: timeframe)
            async let discoveryInsights = calculateDiscoveryInsights(userId: userId, timeframe: timeframe)
            async let milestones = detectMilestones(userId: userId)

            let statistics = UserStatistics(
                watchStats: await watchStats,
                genreDistribution: await genreStats,
                viewingPatterns: await viewingPatterns,
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

    // MARK: - Real data sources (ARCH-001, strada B)
    //
    // These analytics used to read `user_clip_history`, a table nothing writes (0 rows, verified in
    // production) whose queries also named columns that don't exist — so every card silently
    // returned zeros behind `try?`. Rebuilt on the data the app actually has: the user's "seen"
    // list, the "watchlist", per-episode seen state (EpisodeSeenManager), and
    // `user_discovery_interactions`. Two cards had NO honest source and were handled per product
    // decision: Content Performance removed entirely; the viewing heatmap redefined on `added_at`
    // (when you add to lists = activity) and relabelled in the UI, since no watch timestamp exists.

    /// Rows from the user's "seen" list: what they've actually marked watched.
    private func fetchSeenItems(userId: String, since: Date? = nil) async -> [[String: Any]] {
        var sql = """
            SELECT li.media_id, li.media_type, li.title, li.poster_path, li.runtime, li.genres, li.added_at
            FROM list_items li
            JOIN lists l ON l.id = li.list_id
            WHERE l.user_id = ? AND l.type = 'seen'
              AND l.deleted_at IS NULL AND li.deleted_at IS NULL
        """
        var params: [Any] = [userId]
        if let since {
            sql += " AND li.added_at >= ?"
            params.append(since.ISO8601Format())
        }
        return (try? await sqliteService.queryRaw(sql, parameters: params)) ?? []
    }

    /// Count of live items in a given core list ("seen", "watchlist", ...).
    private func listItemCount(userId: String, type: String) async -> Int {
        let sql = """
            SELECT COUNT(*) AS c
            FROM list_items li
            JOIN lists l ON l.id = li.list_id
            WHERE l.user_id = ? AND l.type = ?
              AND l.deleted_at IS NULL AND li.deleted_at IS NULL
        """
        let rows = (try? await sqliteService.queryRaw(sql, parameters: [userId, type])) ?? []
        return rows.first?["c"] as? Int ?? 0
    }

    private func parseGenreIds(_ raw: Any?) -> [Int] {
        guard let json = raw as? String, let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return arr.compactMap { ($0 as? Int) ?? Int("\($0)") }
    }

    /// `.allTime` is sentinel epoch-0; treat it as "no lower bound" so we don't filter on `added_at`.
    private func lowerBound(_ timeframe: Timeframe) -> Date? {
        let start = timeframe.startDate
        return start <= Date(timeIntervalSince1970: 1) ? nil : start
    }

    // MARK: - Watch Statistics

    func calculateWatchStats(userId: String, timeframe: Timeframe) async -> WatchStats {
        let since = lowerBound(timeframe)
        let seen = await fetchSeenItems(userId: userId, since: since)

        let movies = seen.filter { ($0["media_type"] as? String) == "movie" }
        let totalMovies = Set(movies.compactMap { $0["media_id"] as? Int }).count
        let movieMinutes = movies.reduce(0) { $0 + (($1["runtime"] as? Int) ?? 0) }

        // Episodes come from EpisodeSeenManager (UserDefaults-backed). It has no per-episode
        // timestamp, so episode counts are all-time regardless of `timeframe`. Episodes carry no
        // runtime locally, so their watch-time uses a 30-min estimate — labelled as such.
        let episodeCount = await MainActor.run { EpisodeSeenManager.shared.seenKeys.count }
        let episodeMinutesEstimate = episodeCount * 30

        // "Completion" redefined (ARCH-001): the share of your tracked library you've cleared —
        // items in "seen" over items in "seen" + "watchlist". Relabelled in the UI (it is no longer
        // a per-title viewing completion rate, which the app has no data for).
        let seenTotal = seen.count
        let watchlistCount = await listItemCount(userId: userId, type: "watchlist")
        let denominator = seenTotal + watchlistCount
        let completion = denominator > 0 ? Double(seenTotal) / Double(denominator) : 0.0

        return WatchStats(
            totalMovies: totalMovies,
            totalEpisodes: episodeCount,
            totalWatchTimeMinutes: movieMinutes + episodeMinutesEstimate,
            averageSessionMinutes: 0,   // no session data exists; not shown in the dashboard
            completionRate: completion,
            longestSessionMinutes: 0    // no session data exists; not shown in the dashboard
        )
    }

    // MARK: - Genre Distribution

    func calculateGenreDistribution(userId: String, timeframe: Timeframe) async -> GenreStats {
        let seen = await fetchSeenItems(userId: userId, since: lowerBound(timeframe))

        var counts: [Int: Int] = [:]
        var runtimeByGenre: [Int: Int] = [:]
        for row in seen {
            let runtime = (row["runtime"] as? Int) ?? 0
            for gid in parseGenreIds(row["genres"]) {
                counts[gid, default: 0] += 1
                runtimeByGenre[gid, default: 0] += runtime
            }
        }

        let totalCount = counts.values.reduce(0, +)
        let distribution: [GenreDistribution] = counts
            .sorted { $0.value > $1.value }
            .map { gid, count in
                GenreDistribution(
                    genreId: gid,
                    genreName: TMDBGenres.name(for: gid) ?? "Genre \(gid)",
                    count: count,
                    percentage: totalCount > 0 ? Double(count) / Double(totalCount) : 0.0,
                    watchTimeMinutes: runtimeByGenre[gid] ?? 0
                )
            }

        let topGenre = distribution.first ?? GenreDistribution(
            genreId: 0, genreName: "No Data", count: 0, percentage: 0.0, watchTimeMinutes: 0
        )
        let emergingGenre = await detectEmergingGenre(userId: userId)

        return GenreStats(distribution: distribution, topGenre: topGenre, emergingGenre: emergingGenre)
    }

    /// The genre that grew most in the last month vs the month before — measured on when items were
    /// added to the "seen" list (`added_at`), since that's the only real activity timestamp.
    private func detectEmergingGenre(userId: String) async -> GenreDistribution? {
        let calendar = Calendar.current
        let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: Date())!
        let twoMonthsStart = calendar.date(byAdding: .month, value: -2, to: Date())!

        let recent = await fetchSeenItems(userId: userId, since: twoMonthsStart)
        let iso = ISO8601DateFormatter()

        var lastMonth: [Int: Int] = [:]
        var prevMonth: [Int: Int] = [:]
        for row in recent {
            guard let addedStr = row["added_at"] as? String, let added = iso.date(from: addedStr) else { continue }
            let isLastMonth = added >= lastMonthStart
            for gid in parseGenreIds(row["genres"]) {
                if isLastMonth { lastMonth[gid, default: 0] += 1 } else { prevMonth[gid, default: 0] += 1 }
            }
        }

        let emerging = lastMonth
            .filter { $0.value > (prevMonth[$0.key] ?? 0) }
            .max { ($0.value - (prevMonth[$0.key] ?? 0)) < ($1.value - (prevMonth[$1.key] ?? 0)) }

        guard let (gid, count) = emerging else { return nil }
        return GenreDistribution(
            genreId: gid, genreName: TMDBGenres.name(for: gid) ?? "Genre \(gid)",
            count: count, percentage: 0.0, watchTimeMinutes: 0
        )
    }

    // MARK: - Activity Patterns (was "Viewing Patterns")

    /// A 7×24 heatmap of when the user is *active* — i.e. when they add titles to their lists
    /// (`added_at`). Renamed from "viewing" in the UI: the app stores no watch timestamp, so this
    /// honestly measures activity, not viewing hours.
    func calculateViewingPatterns(userId: String) async -> ViewingPatterns {
        var heatmap = Array(repeating: Array(repeating: 0, count: 24), count: 7)

        let sql = """
            SELECT
                CAST(strftime('%w', added_at) AS INTEGER) AS day_of_week,
                CAST(strftime('%H', added_at) AS INTEGER) AS hour,
                COUNT(*) AS additions
            FROM list_items li
            JOIN lists l ON l.id = li.list_id
            WHERE l.user_id = ? AND l.deleted_at IS NULL AND li.deleted_at IS NULL
              AND li.added_at IS NOT NULL
            GROUP BY day_of_week, hour
        """
        let rows = (try? await sqliteService.queryRaw(sql, parameters: [userId])) ?? []
        var byDay: [String: [Int]] = [:]
        let dayNames = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
        for row in rows {
            let day = row["day_of_week"] as? Int ?? 0
            let hour = row["hour"] as? Int ?? 0
            let n = row["additions"] as? Int ?? 0
            guard (0..<7).contains(day), (0..<24).contains(hour) else { continue }
            heatmap[day][hour] = n
            byDay[dayNames[day], default: []].append(n)
        }

        var averageByDayOfWeek: [String: Int] = [:]
        for (name, values) in byDay where !values.isEmpty {
            averageByDayOfWeek[name] = values.reduce(0, +) / values.count
        }

        let preferredTime = determinePreferredTimeOfDay(heatmap: heatmap)
        let (currentStreak, longestStreak) = await calculateActivityStreaks(userId: userId)

        return ViewingPatterns(
            heatmap: heatmap,
            averageByDayOfWeek: averageByDayOfWeek,
            preferredTimeOfDay: preferredTime,
            currentStreak: currentStreak,
            longestStreak: longestStreak
        )
    }

    private func determinePreferredTimeOfDay(heatmap: [[Int]]) -> TimeOfDay {
        var totals: [TimeOfDay: Int] = [.morning: 0, .afternoon: 0, .evening: 0, .night: 0]
        for day in heatmap {
            totals[.morning]! += day[6...11].reduce(0, +)
            totals[.afternoon]! += day[12...17].reduce(0, +)
            totals[.evening]! += day[18...21].reduce(0, +)
            totals[.night]! += (day[22...23] + day[0...5]).reduce(0, +)
        }
        return totals.max(by: { $0.value < $1.value })?.key ?? .evening
    }

    /// Consecutive-day streaks of *activity* (days on which the user added something to a list).
    private func calculateActivityStreaks(userId: String) async -> (current: Int, longest: Int) {
        let sql = """
            SELECT DISTINCT DATE(added_at) AS activity_date
            FROM list_items li
            JOIN lists l ON l.id = li.list_id
            WHERE l.user_id = ? AND l.deleted_at IS NULL AND li.deleted_at IS NULL
              AND li.added_at IS NOT NULL
            ORDER BY activity_date DESC
        """
        let rows = (try? await sqliteService.queryRaw(sql, parameters: [userId])) ?? []
        guard !rows.isEmpty else { return (0, 0) }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let dates: [Date] = rows.compactMap { row in
            guard let s = row["activity_date"] as? String else { return nil }
            return dateFormatter.date(from: s + "T00:00:00Z")
        }
        guard !dates.isEmpty else { return (0, 0) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var currentStreak = 0
        if let mostRecent = dates.first,
           calendar.isDate(mostRecent, inSameDayAs: today) ||
           calendar.isDate(mostRecent, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: today)!) {
            currentStreak = 1
            for i in 1..<dates.count {
                let diff = calendar.dateComponents([.day], from: dates[i], to: dates[i-1]).day ?? 0
                if diff == 1 { currentStreak += 1 } else { break }
            }
        }

        var longestStreak = 1
        var temp = 1
        for i in 1..<dates.count {
            let diff = calendar.dateComponents([.day], from: dates[i], to: dates[i-1]).day ?? 0
            if diff == 1 { temp += 1; longestStreak = max(longestStreak, temp) } else { temp = 1 }
        }

        return (currentStreak, longestStreak)
    }

    // MARK: - Mood Analysis

    /// Mood distribution derived from the genres of what the user has actually seen (their "seen"
    /// list), mapped through a genre→mood table. Previously read the local `user_preferences` table;
    /// now uses the same real source as the rest of the dashboard so it can't diverge from it.
    /// Returns an empty distribution (placeholder) below 5 distinct genres.
    private func calculateMoodAnalysis(userId: String, timeframe: Timeframe) async -> MoodAnalysis {
        let genreToMood: [Int: String] = [
            35: "Light", 16: "Light", 10751: "Light", 10402: "Light",
            12: "Adventurous", 14: "Adventurous", 878: "Adventurous", 10752: "Adventurous", 37: "Adventurous",
            28: "Intense", 53: "Intense", 27: "Intense", 80: "Intense",
            18: "Thoughtful", 99: "Thoughtful", 36: "Thoughtful", 9648: "Thoughtful",
            10749: "Romantic", 10770: "Romantic"
        ]

        let seen = await fetchSeenItems(userId: userId, since: lowerBound(timeframe))
        var distinctGenres = Set<Int>()
        var moodCounts: [String: Int] = [:]
        for row in seen {
            for gid in parseGenreIds(row["genres"]) {
                distinctGenres.insert(gid)
                if let mood = genreToMood[gid] { moodCounts[mood, default: 0] += 1 }
            }
        }

        guard distinctGenres.count >= 5 else {
            return MoodAnalysis(moodDistribution: [:], preferredMoodByTime: [:], emotionalJourney: [])
        }
        return MoodAnalysis(moodDistribution: moodCounts, preferredMoodByTime: [:], emotionalJourney: [])
    }

    // MARK: - Discovery Insights

    func calculateDiscoveryInsights(userId: String, timeframe: Timeframe) async -> DiscoveryInsights {
        let since = timeframe.startDate

        // Breakdown of interactions per carousel type — real columns of user_discovery_interactions.
        let sql = """
            SELECT carousel_type, COUNT(*) AS count
            FROM user_discovery_interactions
            WHERE user_id = ? AND interacted_at >= ?
            GROUP BY carousel_type
        """
        let rows = (try? await sqliteService.queryRaw(sql, parameters: [userId, since.ISO8601Format()])) ?? []
        var sourceBreakdown: [String: Int] = [:]
        for row in rows {
            if let source = row["carousel_type"] as? String, let count = row["count"] as? Int {
                sourceBreakdown[source] = count
            }
        }
        let mostSuccessful = sourceBreakdown.max(by: { $0.value < $1.value })?.key ?? "—"

        // "Click rate" per carousel = share of its interactions that are a tap/click (vs impression).
        let rateSQL = """
            SELECT carousel_type,
                   SUM(CASE WHEN interaction_type IN ('click','tap','select','add_to_list') THEN 1 ELSE 0 END) AS clicks,
                   COUNT(*) AS impressions
            FROM user_discovery_interactions
            WHERE user_id = ? AND interacted_at >= ?
            GROUP BY carousel_type
        """
        let rateRows = (try? await sqliteService.queryRaw(rateSQL, parameters: [userId, since.ISO8601Format()])) ?? []
        var carouselClickRates: [String: Double] = [:]
        for row in rateRows {
            if let carousel = row["carousel_type"] as? String,
               let clicks = row["clicks"] as? Int,
               let impressions = row["impressions"] as? Int, impressions > 0 {
                carouselClickRates[carousel] = Double(clicks) / Double(impressions)
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

        // Movies-seen milestones, from the "seen" list.
        let seen = await fetchSeenItems(userId: userId)
        let totalMovies = Set(seen.filter { ($0["media_type"] as? String) == "movie" }
                                  .compactMap { $0["media_id"] as? Int }).count
        if let highest = [10, 50, 100, 250, 500, 1000].filter({ totalMovies >= $0 }).last {
            milestones.append(Milestone(
                id: "watch_count_\(highest)", type: .watchCount,
                title: "\(highest) Movies Watched",
                description: "You've marked \(totalMovies) movies as seen!",
                achievedAt: Date(), icon: "film.fill"
            ))
        }

        // Activity-streak milestones.
        let (_, longestStreak) = await calculateActivityStreaks(userId: userId)
        if let highest = [7, 14, 30, 60, 100].filter({ longestStreak >= $0 }).last {
            milestones.append(Milestone(
                id: "streak_\(highest)", type: .streak,
                title: "\(highest)-Day Streak",
                description: "You were active \(highest) days in a row!",
                achievedAt: Date(), icon: "flame.fill"
            ))
        }

        // Library-size milestones (total tracked titles across the two core lists).
        let seenCount = await listItemCount(userId: userId, type: "seen")
        let watchlistCount = await listItemCount(userId: userId, type: "watchlist")
        let library = seenCount + watchlistCount
        if let highest = [25, 100, 250, 500, 1000].filter({ library >= $0 }).last {
            milestones.append(Milestone(
                id: "library_\(highest)", type: .discovery,
                title: "\(highest) Titles Tracked",
                description: "Your library holds \(library) titles!",
                achievedAt: Date(), icon: "square.stack.fill"
            ))
        }

        return milestones
    }
}

// MARK: - Data Models

struct UserStatistics: Codable {
    let watchStats: WatchStats
    let genreDistribution: GenreStats
    let viewingPatterns: ViewingPatterns
    // contentPerformance removed (ARCH-001): none of its four sub-lists (highest-rated,
    // most-rewatched, fastest-binged, abandoned) had an honest data source — the app records no
    // ratings, rewatch counts, watch durations, or abandon state.
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
