import Foundation
import Combine

/// Central hub for aggregating and managing user preferences across all app features
/// Tracks interactions from Discovery, Clips, Search, and AI to build comprehensive user profile
@MainActor
class UserPreferenceManager: ObservableObject {
    static let shared = UserPreferenceManager()

    // MARK: - Published Properties

    @Published var userProfile: UserProfile?
    @Published var isLoading = false
    @Published var lastError: String?

    // MARK: - Dependencies

    private let sqliteService: SQLiteService
    private let supabaseClient: SupabaseService
    private var syncEngine: SyncEngineProtocol?

    // MARK: - Constants

    private let deviceId: String
    private let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance", 878: "Science Fiction",
        10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western"
    ]

    // MARK: - Initialization

    private init(
        sqliteService: SQLiteService = .shared,
        supabaseClient: SupabaseService = .shared
    ) {
        self.sqliteService = sqliteService
        self.supabaseClient = supabaseClient

        // Get or create device ID
        if let savedDeviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") {
            self.deviceId = savedDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            UserDefaults.standard.set(newDeviceId, forKey: "deviceIdentifier")
            self.deviceId = newDeviceId
        }

        Logger.info("[UserPreferenceManager] Initialized with device ID: \(deviceId)")
    }

    /// Set SyncEngine after initialization to avoid circular dependency
    func setSyncEngine(_ engine: SyncEngineProtocol) {
        self.syncEngine = engine
    }

    // MARK: - Public Methods

    /// Aggregate preferences from all sources and build comprehensive user profile
    func aggregatePreferences() async -> UserProfile {
        isLoading = true
        defer { isLoading = false }

        guard let userId = AuthService.shared.currentUser?.id else {
            Logger.warning("[UserPreferenceManager] No authenticated user, returning empty profile")
            return UserProfile.empty
        }

        do {
            // 1. Fetch unified preferences from SQLite
            let preferences = try await fetchUnifiedPreferences(userId: userId)

            // 2. Calculate top genres
            let topGenres = calculateTopGenres(from: preferences)

            // 3. Calculate top actors
            let topActors = calculateTopActors(from: preferences)

            // 4. Extract moods
            let moods = extractMoods(from: preferences)

            // 5. Get recent activity
            let recentActivity = await fetchRecentActivity(userId: userId)

            // 6. Analyze watch patterns
            let watchPatterns = await analyzeWatchPatterns(userId: userId)

            // 7. Calculate content type preference
            let contentTypePreference = await calculateContentTypeRatio(userId: userId)

            let profile = UserProfile(
                userId: userId,
                topGenres: topGenres,
                topActors: topActors,
                preferredMoods: moods,
                watchPatterns: watchPatterns,
                contentTypePreference: contentTypePreference,
                recentActivity: recentActivity
            )

            self.userProfile = profile
            Logger.info("[UserPreferenceManager] Profile aggregated: \(topGenres.count) genres, \(topActors.count) actors")

            return profile
        } catch {
            Logger.error("[UserPreferenceManager] Failed to aggregate preferences", error: error)
            lastError = error.localizedDescription
            return UserProfile.empty
        }
    }

    /// Record user interaction from any feature
    func recordInteraction(_ interaction: UserInteraction) {
        Task {
            do {
                // Extract preference signals
                let signals = extractPreferenceSignals(from: interaction)

                guard !signals.isEmpty else {
                    Logger.debug("[UserPreferenceManager] No signals extracted from interaction")
                    return
                }

                // Update unified preferences
                for signal in signals {
                    try await upsertUnifiedPreference(
                        category: signal.category,
                        id: signal.id,
                        name: signal.name,
                        scoreIncrement: signal.weight,
                        source: interaction.source
                    )
                }

                Logger.debug("[UserPreferenceManager] Recorded \(signals.count) signals from \(interaction.source)")

                // Queue for cloud sync if engine is available
                if let syncEngine = syncEngine {
                    for signal in signals {
                        let payload: [String: Any] = [
                            "category": signal.category,
                            "id": signal.id,
                            "name": signal.name,
                            "weight": signal.weight,
                            "source": signal.source.rawValue
                        ]
                        do {
                            try await syncEngine.queueOperation(
                                table: "unified_user_preferences",
                                operationType: "UPSERT",
                                recordId: "\(signal.category)_\(signal.id)",
                                payload: payload,
                                dependsOn: nil
                            )
                        } catch {
                            Logger.error("[UserPreferenceManager] Failed to queue preference sync: \(error)")
                        }
                    }
                }
            } catch {
                Logger.error("[UserPreferenceManager] Failed to record interaction", error: error)
            }
        }
    }

    /// Record a search query for personalization (used by "From Your Searches" carousel).
    func recordSearchQuery(
        query: String,
        mediaType: String? = nil,
        resultCount: Int? = nil
    ) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let userId = AuthService.shared.currentUser?.id else { return }

        let recordId = UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter().string(from: Date())

        let values: [String: Any] = [
            "id": recordId,
            "user_id": userId,
            "device_id": deviceId,
            "query": trimmed,
            "media_type": mediaType ?? NSNull(),
            "result_count": resultCount ?? NSNull(),
            "clicked_media_id": NSNull(),
            "clicked_media_title": NSNull(),
            "searched_at": now,
            "relevance_score": 1.0,
            "synced_at": NSNull()
        ]

        do {
            _ = try await sqliteService.insert("user_search_history", values: values)
            if let syncEngine = syncEngine {
                try await syncEngine.queueOperation(
                    table: "user_search_history",
                    operationType: "INSERT",
                    recordId: recordId,
                    payload: values,
                    dependsOn: nil
                )
            }
        } catch {
            Logger.error("[UserPreferenceManager] Failed to record search query", error: error)
        }
    }

    /// Record a click from a search result (stronger signal than just searching).
    func recordSearchClick(
        query: String,
        clickedMediaId: Int,
        clickedMediaTitle: String,
        clickedMediaType: String,
        resultCount: Int? = nil
    ) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let userId = AuthService.shared.currentUser?.id else { return }

        let recordId = UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter().string(from: Date())

        let values: [String: Any] = [
            "id": recordId,
            "user_id": userId,
            "device_id": deviceId,
            "query": trimmed,
            "media_type": clickedMediaType,
            "result_count": resultCount ?? NSNull(),
            "clicked_media_id": clickedMediaId,
            "clicked_media_title": clickedMediaTitle,
            "searched_at": now,
            "relevance_score": 1.5,
            "synced_at": NSNull()
        ]

        do {
            _ = try await sqliteService.insert("user_search_history", values: values)
            if let syncEngine = syncEngine {
                try await syncEngine.queueOperation(
                    table: "user_search_history",
                    operationType: "INSERT",
                    recordId: recordId,
                    payload: values,
                    dependsOn: nil
                )
            }
        } catch {
            Logger.error("[UserPreferenceManager] Failed to record search click", error: error)
        }
    }

    /// Export user context for AI prompts
    func exportAIContext() -> AIUserContext {
        guard let profile = userProfile else {
            return AIUserContext.empty
        }

        return AIUserContext(
            topGenres: profile.topGenres.prefix(5).map { $0.genreName },
            recentlyWatched: profile.recentActivity.watchedMedia.prefix(5).map {
                "\($0.title)\($0.year.map { " (\($0))" } ?? "")"
            },
            likedTitles: profile.recentActivity.likedMedia.prefix(3).map { $0.title },
            topActors: profile.topActors.prefix(5).map { $0.name },
            lastSearch: profile.recentActivity.lastSearchQuery,
            recentDiscoveryClicks: profile.recentActivity.discoveryClicks.prefix(5).map { $0.title },
            highEngagementClips: profile.recentActivity.topClips.prefix(5).map { $0.title }
        )
    }

    /// Apply preference decay (run weekly via background task)
    func applyPreferenceDecay() async {
        guard let userId = AuthService.shared.currentUser?.id else {
            return
        }

        let decayFactor = 0.95 // 5% decay per week
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let now = ISO8601DateFormatter().string(from: Date())
        let oneWeekAgoString = ISO8601DateFormatter().string(from: oneWeekAgo)

        let sql = """
            UPDATE unified_user_preferences
            SET score = score * ?,
                score_from_clips = score_from_clips * ?,
                score_from_discovery = score_from_discovery * ?,
                score_from_search = score_from_search * ?,
                score_from_ai = score_from_ai * ?,
                score_from_lists = score_from_lists * ?,
                last_decay_at = ?,
                updated_at = ?
            WHERE user_id = ? AND last_interaction_at < ?
        """

        let success = sqliteService.execute(sql, parameters: [
            decayFactor, decayFactor, decayFactor, decayFactor, decayFactor, decayFactor,
            now, now, userId, oneWeekAgoString
        ])

        if success {
            Logger.info("[UserPreferenceManager] Applied preference decay for stale preferences")
        } else {
            Logger.error("[UserPreferenceManager] Failed to apply preference decay")
        }
    }

    // MARK: - Private Methods - Data Fetching

    private func fetchUnifiedPreferences(userId: String) async throws -> [UnifiedPreference] {
        let sql = """
            SELECT * FROM unified_user_preferences
            WHERE user_id = ?
            ORDER BY score DESC
        """

        let rows = try await sqliteService.queryRaw(sql, parameters: [userId])

        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let category = row["preference_category"] as? String,
                  let prefId = row["preference_id"] as? String else {
                return nil
            }

            return UnifiedPreference(
                id: id,
                userId: userId,
                deviceId: deviceId,
                preferenceCategory: category,
                preferenceId: prefId,
                preferenceName: row["preference_name"] as? String,
                score: row["score"] as? Double ?? 0.0,
                scoreFromClips: row["score_from_clips"] as? Double ?? 0.0,
                scoreFromDiscovery: row["score_from_discovery"] as? Double ?? 0.0,
                scoreFromSearch: row["score_from_search"] as? Double ?? 0.0,
                scoreFromAI: row["score_from_ai"] as? Double ?? 0.0,
                scoreFromLists: row["score_from_lists"] as? Double ?? 0.0,
                interactionCount: row["interaction_count"] as? Int ?? 0,
                lastInteractionAt: row["last_interaction_at"] as? String,
                lastDecayAt: row["last_decay_at"] as? String,
                createdAt: row["created_at"] as? String ?? "",
                updatedAt: row["updated_at"] as? String ?? ""
            )
        }
    }

    private func fetchRecentActivity(userId: String) async -> RecentActivity {
        var activity = RecentActivity()

        // Fetch recent watched clips
        let clipsSql = """
            SELECT DISTINCT c.movie_id, c.title, c.media_type
            FROM user_clip_history h
            JOIN clips c ON h.clip_id = c.clip_id
            WHERE h.user_id = ? AND c.movie_id IS NOT NULL
            ORDER BY h.watched_at DESC
            LIMIT 10
        """

        if let clipRows = try? await sqliteService.queryRaw(clipsSql, parameters: [userId]) {
            activity.watchedMedia = clipRows.compactMap { row in
                guard let id = row["movie_id"] as? Int,
                      let title = row["title"] as? String else {
                    return nil
                }
                let mediaType = MediaType(rawValue: row["media_type"] as? String ?? "movie") ?? .movie
                return MediaSummary(id: id, title: title, mediaType: mediaType)
            }
        }

        // Fetch liked movies/shows
        let likesSql = """
            SELECT media_id, media_type FROM movie_reactions
            WHERE user_id = ? AND reaction_type = 'like'
            ORDER BY created_at DESC
            LIMIT 5
        """

        if let likeRows = try? await sqliteService.queryRaw(likesSql, parameters: [userId]) {
            activity.likedMedia = likeRows.compactMap { row in
                guard let id = row["media_id"] as? Int else { return nil }
                let mediaType = MediaType(rawValue: row["media_type"] as? String ?? "movie") ?? .movie
                return MediaSummary(id: id, title: "Media \(id)", mediaType: mediaType)
            }
        }

        // Fetch last search query
        let searchSql = """
            SELECT query FROM user_search_history
            WHERE user_id = ?
            ORDER BY searched_at DESC
            LIMIT 1
        """

        if let searchRows = try? await sqliteService.queryRaw(searchSql, parameters: [userId]),
           let query = searchRows.first?["query"] as? String {
            activity.lastSearchQuery = query
        }

        // Fetch watchlist
        let watchlistSql = """
            SELECT media_id, title, media_type FROM list_items
            WHERE user_id = ? AND deleted_at IS NULL
            LIMIT 10
        """

        if let watchlistRows = try? await sqliteService.queryRaw(watchlistSql, parameters: [userId]) {
            activity.watchlist = watchlistRows.compactMap { row in
                guard let id = row["media_id"] as? Int,
                      let title = row["title"] as? String else {
                    return nil
                }
                let mediaType = MediaType(rawValue: row["media_type"] as? String ?? "movie") ?? .movie
                return MediaSummary(id: id, title: title, mediaType: mediaType)
            }
        }

        return activity
    }

    private func analyzeWatchPatterns(userId: String) async -> WatchPattern {
        var pattern = WatchPattern()

        let sql = """
            SELECT
                AVG(watch_duration) as avg_duration,
                AVG(completion_rate) as avg_completion
            FROM user_clip_history
            WHERE user_id = ?
        """

        if let rows = try? await sqliteService.queryRaw(sql, parameters: [userId]),
           let row = rows.first {
            pattern.averageWatchDuration = row["avg_duration"] as? Double ?? 0
            pattern.completionRate = row["avg_completion"] as? Double ?? 0
        }

        // Analyze time-of-day patterns
        pattern.timeOfDayPreferences = await analyzeTimeOfDayPatterns(userId: userId)

        return pattern
    }

    /// Analyze when user watches content to detect time-of-day preferences
    private func analyzeTimeOfDayPatterns(userId: String) async -> [TimeOfDay: Double] {
        let sql = """
            SELECT
                CASE
                    WHEN CAST(strftime('%H', watched_at) AS INTEGER) BETWEEN 6 AND 11 THEN 'morning'
                    WHEN CAST(strftime('%H', watched_at) AS INTEGER) BETWEEN 12 AND 17 THEN 'afternoon'
                    WHEN CAST(strftime('%H', watched_at) AS INTEGER) BETWEEN 18 AND 21 THEN 'evening'
                    ELSE 'night'
                END as time_of_day,
                COUNT(*) as watch_count,
                AVG(engagement_score) as avg_engagement
            FROM user_clip_history
            WHERE user_id = ?
              AND watched_at IS NOT NULL
              AND watched_at > datetime('now', '-30 days')
            GROUP BY time_of_day
        """

        guard let rows = try? await sqliteService.queryRaw(sql, parameters: [userId]) else {
            return [:]
        }

        var preferences: [TimeOfDay: Double] = [:]
        var totalWatches = 0.0

        // First pass: calculate total watches
        for row in rows {
            totalWatches += (row["watch_count"] as? Double ?? 0.0)
        }

        guard totalWatches > 0 else { return [:] }

        // Second pass: calculate weighted preferences
        for row in rows {
            guard let timeOfDayStr = row["time_of_day"] as? String,
                  let timeOfDay = TimeOfDay(rawValue: timeOfDayStr),
                  let watchCount = row["watch_count"] as? Double,
                  let avgEngagement = row["avg_engagement"] as? Double else {
                continue
            }

            // Preference score = (watch frequency * 0.7) + (engagement * 0.3)
            let frequency = watchCount / totalWatches
            let engagementNormalized = min(avgEngagement / 5.0, 1.0) // Normalize to 0-1
            let preference = (frequency * 0.7) + (engagementNormalized * 0.3)

            preferences[timeOfDay] = preference
        }

        Logger.debug("[UserPreferenceManager] Time patterns for user \(userId): \(preferences)")
        return preferences
    }

    /// Record a watch event with time-of-day tracking
    func recordWatchEvent(clipId: String, hour: Int, engagementScore: Double) async {
        guard let userId = AuthService.shared.currentUser?.id else { return }

        let timeOfDay: TimeOfDay
        switch hour {
        case 6...11:
            timeOfDay = .morning
        case 12...17:
            timeOfDay = .afternoon
        case 18...21:
            timeOfDay = .evening
        default:
            timeOfDay = .night
        }

        // Update time-of-day pattern in memory (lightweight tracking)
        let recordId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        let values: [String: Any] = [
            "id": recordId,
            "user_id": userId,
            "device_id": deviceId,
            "time_of_day": timeOfDay.rawValue,
            "engagement_score": engagementScore,
            "recorded_at": now
        ]

        _ = try? await sqliteService.insert("user_time_patterns", values: values)
    }

    /// Get preferred time of day for content recommendations
    func getPreferredTimeOfDay() async -> TimeOfDay? {
        guard userProfile != nil else {
            await aggregatePreferences()
            return nil
        }

        guard let patterns = userProfile?.watchPatterns.timeOfDayPreferences,
              !patterns.isEmpty else {
            return nil
        }

        // Return time slot with highest preference score
        return patterns.max(by: { $0.value < $1.value })?.key
    }

    private func calculateContentTypeRatio(userId: String) async -> ContentTypeRatio {
        let sql = """
            SELECT
                SUM(CASE WHEN media_type = 'movie' THEN 1 ELSE 0 END) as movies,
                SUM(CASE WHEN media_type = 'tv' THEN 1 ELSE 0 END) as tv,
                COUNT(*) as total
            FROM user_clip_history h
            JOIN clips c ON h.clip_id = c.clip_id
            WHERE h.user_id = ?
        """

        if let rows = try? await sqliteService.queryRaw(sql, parameters: [userId]),
           let row = rows.first,
           let total = row["total"] as? Int, total > 0 {
            let movies = row["movies"] as? Int ?? 0
            let tv = row["tv"] as? Int ?? 0
            let movieRatio = Double(movies) / Double(total)
            let tvRatio = Double(tv) / Double(total)
            return ContentTypeRatio(movieRatio: movieRatio, tvRatio: tvRatio)
        }

        return ContentTypeRatio(movieRatio: 0.5, tvRatio: 0.5)
    }

    // MARK: - Private Methods - Preference Calculation

    private func calculateTopGenres(from preferences: [UnifiedPreference]) -> [GenrePreference] {
        let genrePrefs = preferences.filter { $0.preferenceCategory == "genre" }

        return genrePrefs.prefix(10).map { pref in
            let genreId = Int(pref.preferenceId) ?? 0
            let genreName = genreNames[genreId] ?? pref.preferenceName ?? "Unknown"

            return GenrePreference(
                genreId: genreId,
                genreName: genreName,
                totalScore: pref.score,
                sourceBreakdown: [
                    "clips": pref.scoreFromClips,
                    "discovery": pref.scoreFromDiscovery,
                    "search": pref.scoreFromSearch,
                    "ai": pref.scoreFromAI,
                    "lists": pref.scoreFromLists
                ]
            )
        }
    }

    private func calculateTopActors(from preferences: [UnifiedPreference]) -> [ActorPreference] {
        let actorPrefs = preferences.filter { $0.preferenceCategory == "actor" }

        return actorPrefs.prefix(10).map { pref in
            ActorPreference(
                actorId: Int(pref.preferenceId) ?? 0,
                name: pref.preferenceName ?? "Unknown",
                score: pref.score
            )
        }
    }

    private func extractMoods(from preferences: [UnifiedPreference]) -> [Mood] {
        let moodPrefs = preferences.filter { $0.preferenceCategory == "mood" }
            .sorted { $0.score > $1.score }
            .prefix(5)

        return moodPrefs.compactMap { pref in
            Mood(rawValue: pref.preferenceId.lowercased())
        }
    }

    // MARK: - Private Methods - Preference Updates

    private func upsertUnifiedPreference(
        category: String,
        id: String,
        name: String,
        scoreIncrement: Double,
        source: InteractionSource
    ) async throws {
        guard let userId = AuthService.shared.currentUser?.id else {
            throw PreferenceError.notAuthenticated
        }

        let sourceColumn: String
        switch source {
        case .clips: sourceColumn = "score_from_clips"
        case .discovery: sourceColumn = "score_from_discovery"
        case .search: sourceColumn = "score_from_search"
        case .ai: sourceColumn = "score_from_ai"
        case .lists: sourceColumn = "score_from_lists"
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let prefId = UUID().uuidString

        let sql = """
            INSERT INTO unified_user_preferences (
                id, user_id, device_id, preference_category, preference_id,
                preference_name, score, \(sourceColumn), interaction_count,
                last_interaction_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
            ON CONFLICT(user_id, preference_category, preference_id) DO UPDATE SET
                score = score + ?,
                \(sourceColumn) = \(sourceColumn) + ?,
                interaction_count = interaction_count + 1,
                last_interaction_at = ?,
                updated_at = ?
        """

        let success = sqliteService.execute(sql, parameters: [
            prefId, userId, deviceId, category, id,
            name, scoreIncrement, scoreIncrement, now, now, now,
            scoreIncrement, scoreIncrement, now, now
        ])

        if !success {
            throw PreferenceError.databaseError
        }
    }

    private func extractPreferenceSignals(from interaction: UserInteraction) -> [PreferenceSignal] {
        var signals: [PreferenceSignal] = []
        let baseWeight = interaction.engagementScore

        // Extract genre signals
        if let genreIds = interaction.genreIds {
            for genreId in genreIds {
                let genreName = genreNames[genreId] ?? "Unknown"
                signals.append(PreferenceSignal(
                    category: "genre",
                    id: String(genreId),
                    name: genreName,
                    weight: baseWeight * 10.0, // Genres are weighted heavily
                    source: interaction.source
                ))
            }
        }

        // Extract actor signals
        if let actorIds = interaction.actorIds {
            for actorId in actorIds {
                signals.append(PreferenceSignal(
                    category: "actor",
                    id: String(actorId),
                    name: interaction.metadata["actor_\(actorId)"] ?? "Unknown",
                    weight: baseWeight * 5.0,
                    source: interaction.source
                ))
            }
        }

        // Extract mood from metadata
        if let mood = interaction.metadata["mood"] {
            signals.append(PreferenceSignal(
                category: "mood",
                id: mood.lowercased(),
                name: mood,
                weight: baseWeight * 3.0,
                source: interaction.source
            ))
        }

        return signals
    }
}

// MARK: - Supporting Models

struct UnifiedPreference {
    let id: String
    let userId: String
    let deviceId: String
    let preferenceCategory: String
    let preferenceId: String
    let preferenceName: String?
    let score: Double
    let scoreFromClips: Double
    let scoreFromDiscovery: Double
    let scoreFromSearch: Double
    let scoreFromAI: Double
    let scoreFromLists: Double
    let interactionCount: Int
    let lastInteractionAt: String?
    let lastDecayAt: String?
    let createdAt: String
    let updatedAt: String
}

// MARK: - Errors

enum PreferenceError: LocalizedError {
    case notAuthenticated
    case databaseError
    case invalidData

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "User must be authenticated to record preferences"
        case .databaseError:
            return "Failed to update preferences in database"
        case .invalidData:
            return "Invalid preference data provided"
        }
    }
}
