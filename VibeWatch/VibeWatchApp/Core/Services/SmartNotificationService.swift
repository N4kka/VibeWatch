import Foundation
import UserNotifications
import UIKit

/// Manages smart, personalized push notifications for users
/// Sends targeted notifications based on user preferences and behavior
@MainActor
class SmartNotificationService: NSObject, ObservableObject {
    static let shared = SmartNotificationService()

    // MARK: - Published Properties

    @Published var notificationPermissionGranted = false
    @Published var preferences: NotificationPreferences?

    // MARK: - Dependencies

    private let sqliteService: SQLiteService
    private let tmdbService: TMDBServiceProtocol
    private let preferenceManager: UserPreferenceManager
    private let cerebrasService: CerebrasService
    private let notificationCenter = UNUserNotificationCenter.current()

    // MARK: - Constants

    private let deviceId: String
    private let maxDailyNotifications = 3
    private static let releaseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Initialization

    private override init() {
        self.sqliteService = SQLiteService.shared
        self.tmdbService = TMDBService.shared
        self.preferenceManager = UserPreferenceManager.shared
        self.cerebrasService = CerebrasService.shared

        // Get device ID
        if let savedDeviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") {
            self.deviceId = savedDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            UserDefaults.standard.set(newDeviceId, forKey: "deviceIdentifier")
            self.deviceId = newDeviceId
        }

        super.init()
        notificationCenter.delegate = self

        Logger.info("[SmartNotificationService] Initialized")
    }

    // MARK: - Permission Management

    /// Request notification permissions from user
    func requestPermissions() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])

            await MainActor.run {
                self.notificationPermissionGranted = granted
            }

            if granted {
                Logger.info("[SmartNotificationService] ✅ Notification permissions granted")
            } else {
                Logger.warning("[SmartNotificationService] ❌ Notification permissions denied")
            }

            return granted
        } catch {
            Logger.error("[SmartNotificationService] Failed to request permissions", error: error)
            return false
        }
    }

    /// Check current notification permission status
    func checkPermissionStatus() async {
        let settings = await notificationCenter.notificationSettings()

        await MainActor.run {
            self.notificationPermissionGranted = settings.authorizationStatus == .authorized
        }
    }

    // MARK: - Preference Management

    /// Load user's notification preferences from database
    func loadPreferences(userId: String) async {
        let sql = """
            SELECT * FROM user_notification_preferences
            WHERE user_id = ?
        """

        guard let rows = try? await sqliteService.queryRaw(sql, parameters: [userId]),
              let row = rows.first else {
            // Create default preferences if none exist
            await createDefaultPreferences(userId: userId)
            return
        }

        let preferences = NotificationPreferences(
            enableNewEpisodes: (row["enable_new_episodes"] as? Int ?? 1) == 1,
            enableReleaseAlerts: (row["enable_release_alerts"] as? Int ?? 1) == 1,
            enableActorAlerts: (row["enable_actor_alerts"] as? Int ?? 1) == 1,
            enableSimilarContent: (row["enable_similar_content"] as? Int ?? 1) == 1,
            enableWatchlistAlerts: (row["enable_watchlist_alerts"] as? Int ?? 1) == 1,
            enableMilestones: (row["enable_milestones"] as? Int ?? 1) == 1,
            maxDailyNotifications: row["max_daily_notifications"] as? Int ?? 3,
            quietHoursStart: row["quiet_hours_start"] as? Int ?? 22,
            quietHoursEnd: row["quiet_hours_end"] as? Int ?? 8,
            customActorAlerts: parseJSONArray(row["custom_actor_alerts"] as? String),
            customGenreAlerts: parseJSONArray(row["custom_genre_alerts"] as? String)
        )

        await MainActor.run {
            self.preferences = preferences
        }

        Logger.debug("[SmartNotificationService] Loaded preferences for user: \(userId)")
    }

    /// Save user's notification preferences to database
    func savePreferences(userId: String, preferences: NotificationPreferences) async {
        let sql = """
            INSERT OR REPLACE INTO user_notification_preferences (
                user_id, enable_new_episodes, enable_release_alerts,
                enable_actor_alerts, enable_similar_content, enable_watchlist_alerts,
                enable_milestones, max_daily_notifications, quiet_hours_start,
                quiet_hours_end, custom_actor_alerts, custom_genre_alerts, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        let customActorsJSON = try? JSONEncoder().encode(preferences.customActorAlerts)
        let customGenresJSON = try? JSONEncoder().encode(preferences.customGenreAlerts)

        let success = sqliteService.execute(sql, parameters: [
            userId,
            preferences.enableNewEpisodes ? 1 : 0,
            preferences.enableReleaseAlerts ? 1 : 0,
            preferences.enableActorAlerts ? 1 : 0,
            preferences.enableSimilarContent ? 1 : 0,
            preferences.enableWatchlistAlerts ? 1 : 0,
            preferences.enableMilestones ? 1 : 0,
            preferences.maxDailyNotifications,
            preferences.quietHoursStart,
            preferences.quietHoursEnd,
            String(data: customActorsJSON ?? Data(), encoding: .utf8) ?? "[]",
            String(data: customGenresJSON ?? Data(), encoding: .utf8) ?? "[]",
            ISO8601DateFormatter().string(from: Date())
        ])

        if success {
            await MainActor.run {
                self.preferences = preferences
            }
            Logger.info("[SmartNotificationService] Saved preferences for user: \(userId)")
        }
    }

    private func createDefaultPreferences(userId: String) async {
        let defaultPreferences = NotificationPreferences()
        await savePreferences(userId: userId, preferences: defaultPreferences)
    }

    // MARK: - Notification Scheduling

    /// Schedule all pending smart notifications
    func schedulePersonalizedNotifications(userId: String) async {
        guard notificationPermissionGranted else {
            Logger.warning("[SmartNotificationService] Cannot schedule - permissions not granted")
            return
        }

        let resolvedPreferences: NotificationPreferences?
        if let existing = preferences {
            resolvedPreferences = existing
        } else {
            resolvedPreferences = await loadAndReturnPreferences(userId: userId)
        }
        guard let preferences = resolvedPreferences else { return }

        // Check daily limit
        let todayCount = await getTodayNotificationCount(userId: userId)
        guard todayCount < preferences.maxDailyNotifications else {
            Logger.info("[SmartNotificationService] Daily notification limit reached (\(todayCount)/\(preferences.maxDailyNotifications))")
            return
        }

        Logger.info("[SmartNotificationService] Scheduling notifications for user: \(userId)")

        var scheduledCount = 0
        let remainingSlots = preferences.maxDailyNotifications - todayCount

        // 1. Check for new episodes (highest priority)
        if preferences.enableNewEpisodes && scheduledCount < remainingSlots {
            let newEpisodes = await detectNewEpisodes(userId: userId)
            for episode in newEpisodes.prefix(remainingSlots - scheduledCount) {
                await scheduleNewEpisodeNotification(userId: userId, notification: episode)
                scheduledCount += 1
            }
        }

        // 2. Check for personalized release alerts
        if preferences.enableReleaseAlerts && scheduledCount < remainingSlots {
            let releases = await detectPersonalizedReleases(userId: userId)
            if let release = releases.first {
                await scheduleReleaseNotification(userId: userId, notification: release)
                scheduledCount += 1
            }
        }

        // 3. Check for favorite actor/director content
        if preferences.enableActorAlerts && scheduledCount < remainingSlots {
            let actorAlerts = await detectFavoriteActorContent(userId: userId)
            if let actorAlert = actorAlerts.first {
                await scheduleActorNotification(userId: userId, notification: actorAlert)
                scheduledCount += 1
            }
        }

        // 4. Similar content recommendations
        if preferences.enableSimilarContent && scheduledCount < remainingSlots {
            let similarContent = await detectSimilarContent(userId: userId)
            if let similar = similarContent.first {
                await scheduleSimilarContentNotification(userId: userId, notification: similar)
                scheduledCount += 1
            }
        }

        // 5. Watchlist availability alerts
        if preferences.enableWatchlistAlerts && scheduledCount < remainingSlots {
            let watchlistAlerts = await detectWatchlistAvailability(userId: userId)
            if let alert = watchlistAlerts.first {
                await scheduleWatchlistNotification(userId: userId, notification: alert)
                scheduledCount += 1
            }
        }

        // 6. Milestone achievements
        if preferences.enableMilestones && scheduledCount < remainingSlots {
            let milestones = await detectMilestones(userId: userId)
            if let milestone = milestones.first {
                await scheduleMilestoneNotification(userId: userId, notification: milestone)
                scheduledCount += 1
            }
        }

        Logger.info("[SmartNotificationService] Scheduled \(scheduledCount) notifications")
    }

    // MARK: - Detection Methods

    /// Detect new episodes for shows user is watching
    private func detectNewEpisodes(userId: String) async -> [NewEpisodeNotification] {
        // Get shows user is watching (from watchlist + recent history)
        let watchingShows = await getWatchingShows(userId: userId)

        var notifications: [NewEpisodeNotification] = []

        for show in watchingShows {
            // Get latest episode from TMDB
            guard let showDetails = try? await tmdbService.getTVShowDetails(id: show.id) else {
                continue
            }

            // Check if there's a new episode since last watched
            let lastWatched = await getLastWatchedEpisode(userId: userId, showId: show.id)

            // Find next unwatched episode
            if let nextEpisode = findNextEpisode(show: showDetails, after: lastWatched) {
                // Check if episode has aired
                guard nextEpisode.airDate <= Date() else { continue }

                // Check if we've already notified
                let contentId = "\(show.id)_S\(nextEpisode.seasonNumber)E\(nextEpisode.episodeNumber)"
                let alreadySent = await hasNotificationBeenSent(
                    userId: userId,
                    type: .newEpisode,
                    contentId: contentId
                )

                guard !alreadySent else { continue }

                notifications.append(NewEpisodeNotification(
                    show: show,
                    episode: nextEpisode
                ))
            }
        }

        return notifications
    }

    /// Detect new releases matching user's top genres
    private func detectPersonalizedReleases(userId: String) async -> [ReleaseNotification] {
        let profile = await preferenceManager.aggregatePreferences()
        let topGenres = profile.topGenres.prefix(3).map(\.genreId)

        guard !topGenres.isEmpty else { return [] }

        // Get new releases from last 7 days
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!

        // Fetch trending movies (new releases appear here)
        guard let trending = try? await tmdbService.getTrendingMovies(timeWindow: .week, page: 1) else {
            return []
        }

        var notifications: [ReleaseNotification] = []

        for movie in trending.results {
            // Filter by release date (must be recent)
            guard let releaseDate = parseReleaseDate(movie.releaseDate),
                  releaseDate >= weekAgo else {
                continue
            }

            // Check genre match (at least 2 matching genres)
            let genreMatches = (movie.genreIds ?? []).filter { topGenres.contains($0) }
            guard genreMatches.count >= 2 else { continue }

            // Calculate personalization score
            let score = calculatePersonalizationScore(movie: movie, userProfile: profile)
            guard score > 50 else { continue }

            // Check if already notified
            let alreadySent = await hasNotificationBeenSent(
                userId: userId,
                type: .releaseAlert,
                contentId: String(movie.id)
            )

            guard !alreadySent else { continue }

            let matchReasons = genreMatches.compactMap { genreId in
                profile.topGenres.first(where: { $0.genreId == genreId })?.genreName
            }

            notifications.append(ReleaseNotification(
                movie: movie,
                matchReason: "Matches your love for \(matchReasons.joined(separator: " and "))"
            ))
        }

        return notifications.prefix(1).map { $0 } // Max 1 per day
    }

    /// Detect new content from favorite actors/directors
    private func detectFavoriteActorContent(userId: String) async -> [ActorNotification] {
        let profile = await preferenceManager.aggregatePreferences()
        let topActors = profile.topActors.prefix(5)

        guard !topActors.isEmpty else { return [] }

        var notifications: [ActorNotification] = []

        // Check each top actor for new content
        for actor in topActors {
            // Get actor's recent credits
            guard let credits = try? await tmdbService.getPersonCombinedCredits(id: actor.actorId) else {
                continue
            }

            // Find movies released in last 30 days
            let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!

            for credit in credits.cast where credit.mediaType == .movie {
                guard let releaseDate = parseReleaseDate(credit.releaseDate),
                      releaseDate >= monthAgo,
                      releaseDate <= Date() else {
                    continue
                }

                // Check if already notified
                let contentId = "\(actor.actorId)_\(credit.id)"
                let alreadySent = await hasNotificationBeenSent(
                    userId: userId,
                    type: .actorAlert,
                    contentId: contentId
                )

                guard !alreadySent else { continue }

                notifications.append(ActorNotification(
                    actor: actor,
                    movie: movieFromCredit(credit)
                ))
            }
        }

        return notifications.prefix(2).map { $0 } // Max 2 per week
    }

    /// Detect similar content to what user loved
    private func detectSimilarContent(userId: String) async -> [SimilarContentNotification] {
        let profile = await preferenceManager.aggregatePreferences()

        guard let topLiked = profile.recentActivity.likedMedia.first else {
            return []
        }

        // Get similar movies
        guard let similar = try? await tmdbService.getSimilarMovies(id: topLiked.id, page: 1) else {
            return []
        }

        var notifications: [SimilarContentNotification] = []

        for movie in similar.results.prefix(3) {
            // Check if already notified
            let contentId = "\(topLiked.id)_\(movie.id)"
            let alreadySent = await hasNotificationBeenSent(
                userId: userId,
                type: .similarContent,
                contentId: contentId
            )

            guard !alreadySent else { continue }

            notifications.append(SimilarContentNotification(
                originalMovie: topLiked,
                similarMovie: movie
            ))
        }

        return notifications
    }

    /// Detect when watchlist items become available
    private func detectWatchlistAvailability(userId: String) async -> [WatchlistNotification] {
        // Get user's watchlist items
        let sql = """
            SELECT media_id, media_type, added_at
            FROM list_items
            WHERE user_id = ? AND deleted_at IS NULL
            ORDER BY added_at DESC
            LIMIT 50
        """

        guard let rows = try? await sqliteService.queryRaw(sql, parameters: [userId]) else {
            return []
        }

        var notifications: [WatchlistNotification] = []
        let profile = await preferenceManager.aggregatePreferences()

        for row in rows {
            guard let mediaId = row["media_id"] as? Int,
                  let mediaType = row["media_type"] as? String else {
                continue
            }

            // Check if we've already notified about this item
            let contentId = "\(mediaId)_\(mediaType)"
            let alreadySent = await hasNotificationBeenSent(
                userId: userId,
                type: .watchlistAlert,
                contentId: contentId
            )

            guard !alreadySent else { continue }

            // For MVP: Notify user that item is in watchlist (streaming availability would require additional API)
            // Future enhancement: Check TMDB watch providers for actual availability
            // For now, just notify about highly-rated watchlist items periodically
            if mediaType == "movie" {
                guard let movie = try? await tmdbService.getMovieDetails(id: mediaId) else {
                    continue
                }

                // Only notify about highly-rated items (8.0+)
                guard movie.voteAverage >= 8.0 else { continue }

                let nudgeMessage = await generateSmartNudgeMessage(
                    userProfile: profile,
                    title: movie.title
                )

                notifications.append(WatchlistNotification(
                    mediaId: mediaId,
                    title: movie.title,
                    message: nudgeMessage
                ))

                break // Max 1 watchlist notification
            }
        }

        return notifications
    }

    private func generateSmartNudgeMessage(userProfile: UserProfile, title: String) async -> String {
        let fallback = "Don't forget: \(title) is in your watchlist"

        do {
            let response = try await cerebrasService.generateSmartNudge(
                userProfile: userProfile,
                candidates: [title]
            )

            let parts = response.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2, !parts[1].isEmpty {
                return parts[1]
            }
            if !response.isEmpty {
                return response
            }
        } catch {
            Logger.warning("[SmartNotificationService] Smart nudge generation failed: \(error.localizedDescription)")
        }

        return fallback
    }

    /// Detect user milestones and achievements
    private func detectMilestones(userId: String) async -> [MilestoneNotification] {
        var milestones: [MilestoneNotification] = []

        // Check for watch count milestones
        let watchCountSql = """
            SELECT COUNT(DISTINCT media_id) as count
            FROM user_clip_history
            WHERE user_id = ?
        """

        if let rows = try? await sqliteService.queryRaw(watchCountSql, parameters: [userId]),
           let count = rows.first?["count"] as? Int {

            // Milestone levels: 10, 50, 100, 250, 500, 1000
            let milestoneLevels = [10, 50, 100, 250, 500, 1000]

            for level in milestoneLevels {
                if count == level {
                    let contentId = "watch_count_\(level)"
                    let alreadySent = await hasNotificationBeenSent(
                        userId: userId,
                        type: .milestone,
                        contentId: contentId
                    )

                    guard !alreadySent else { continue }

                    milestones.append(MilestoneNotification(
                        type: .watchCount(level),
                        title: "🎉 Milestone Achieved!",
                        message: "You've watched \(level) movies and shows!"
                    ))

                    break // Only one milestone at a time
                }
            }
        }

        // Check for watch streak milestones
        let streakSql = """
            SELECT COUNT(DISTINCT DATE(watched_at)) as streak
            FROM user_clip_history
            WHERE user_id = ?
              AND watched_at >= datetime('now', '-30 days')
            GROUP BY user_id
            HAVING COUNT(DISTINCT DATE(watched_at)) >= 7
        """

        if let rows = try? await sqliteService.queryRaw(streakSql, parameters: [userId]),
           let streak = rows.first?["streak"] as? Int {

            let streakLevels = [7, 14, 30]

            for level in streakLevels {
                if streak == level {
                    let contentId = "watch_streak_\(level)"
                    let alreadySent = await hasNotificationBeenSent(
                        userId: userId,
                        type: .milestone,
                        contentId: contentId
                    )

                    guard !alreadySent else { continue }

                    milestones.append(MilestoneNotification(
                        type: .watchStreak(level),
                        title: "🔥 \(level)-Day Streak!",
                        message: "Keep up the momentum!"
                    ))

                    break
                }
            }
        }

        return milestones
    }

    private func parseReleaseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return Self.releaseDateFormatter.date(from: value)
    }

    private func movieFromCredit(_ credit: PersonCredit) -> Movie {
        Movie(
            id: credit.id,
            title: credit.title,
            overview: "",
            posterPath: credit.posterPath,
            backdropPath: nil,
            releaseDate: credit.releaseDate,
            voteAverage: 0,
            voteCount: 0,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: 0,
            runtime: nil,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }

    // MARK: - Notification Builders

    private func scheduleNewEpisodeNotification(userId: String, notification: NewEpisodeNotification) async {
        let content = UNMutableNotificationContent()
        content.title = "New Episode Available!"
        content.body = "\(notification.show.title) - S\(notification.episode.seasonNumber)E\(notification.episode.episodeNumber): \(notification.episode.name)"
        content.sound = .default
        content.badge = 1
        content.userInfo = [
            "type": "new_episode",
            "show_id": notification.show.id,
            "season": notification.episode.seasonNumber,
            "episode": notification.episode.episodeNumber
        ]

        // Schedule immediately (unless in quiet hours)
        if await canSendNow() {
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )

            try? await notificationCenter.add(request)

            // Record in database
            await recordNotificationSent(
                userId: userId,
                type: .newEpisode,
                contentId: "\(notification.show.id)_S\(notification.episode.seasonNumber)E\(notification.episode.episodeNumber)"
            )

            Logger.info("[SmartNotificationService] Scheduled new episode notification: \(notification.show.title)")
        }
    }

    private func scheduleReleaseNotification(userId: String, notification: ReleaseNotification) async {
        let content = UNMutableNotificationContent()
        content.title = "New Release You'll Love"
        content.body = "\(notification.movie.title) - \(notification.matchReason)"
        content.sound = .default
        content.badge = 1
        content.userInfo = [
            "type": "release_alert",
            "movie_id": notification.movie.id
        ]

        if await canSendNow() {
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )

            try? await notificationCenter.add(request)

            await recordNotificationSent(
                userId: userId,
                type: .releaseAlert,
                contentId: String(notification.movie.id)
            )

            Logger.info("[SmartNotificationService] Scheduled release notification: \(notification.movie.title)")
        }
    }

    private func scheduleActorNotification(userId: String, notification: ActorNotification) async {
        let content = UNMutableNotificationContent()
        content.title = "\(notification.actor.name) Has New Content!"
        content.body = "\(notification.movie.title) is now available"
        content.sound = .default
        content.badge = 1
        content.userInfo = [
            "type": "actor_alert",
            "actor_id": notification.actor.actorId,
            "movie_id": notification.movie.id
        ]

        if await canSendNow() {
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )

            try? await notificationCenter.add(request)

            await recordNotificationSent(
                userId: userId,
                type: .actorAlert,
                contentId: "\(notification.actor.actorId)_\(notification.movie.id)"
            )

            Logger.info("[SmartNotificationService] Scheduled actor notification: \(notification.actor.name)")
        }
    }

    private func scheduleSimilarContentNotification(userId: String, notification: SimilarContentNotification) async {
        let content = UNMutableNotificationContent()
        content.title = "You Might Love This"
        content.body = "Loved \(notification.originalMovie.title)? Try \(notification.similarMovie.title)"
        content.sound = .default
        content.badge = 1
        content.userInfo = [
            "type": "similar_content",
            "original_id": notification.originalMovie.id,
            "similar_id": notification.similarMovie.id
        ]

        if await canSendNow() {
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )

            try? await notificationCenter.add(request)

            await recordNotificationSent(
                userId: userId,
                type: .similarContent,
                contentId: "\(notification.originalMovie.id)_\(notification.similarMovie.id)"
            )

            Logger.info("[SmartNotificationService] Scheduled similar content notification")
        }
    }

    private func scheduleWatchlistNotification(userId: String, notification: WatchlistNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.message
        content.sound = .default
        content.badge = 1
        content.userInfo = [
            "type": "watchlist_alert",
            "media_id": notification.mediaId
        ]

        if await canSendNow() {
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )

            try? await notificationCenter.add(request)

            await recordNotificationSent(
                userId: userId,
                type: .watchlistAlert,
                contentId: String(notification.mediaId)
            )

            Logger.info("[SmartNotificationService] Scheduled watchlist notification: \(notification.title)")
        }
    }

    private func scheduleMilestoneNotification(userId: String, notification: MilestoneNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.message
        content.sound = .default
        content.badge = 1

        let contentId: String
        switch notification.type {
        case .watchCount(let count):
            contentId = "watch_count_\(count)"
        case .watchStreak(let days):
            contentId = "watch_streak_\(days)"
        }

        content.userInfo = [
            "type": "milestone",
            "milestone_id": contentId
        ]

        if await canSendNow() {
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            )

            try? await notificationCenter.add(request)

            await recordNotificationSent(
                userId: userId,
                type: .milestone,
                contentId: contentId
            )

            Logger.info("[SmartNotificationService] Scheduled milestone notification: \(notification.title)")
        }
    }

    // MARK: - Helper Methods

    private func canSendNow() async -> Bool {
        guard let prefs = preferences else {
            Logger.warning("[SmartNotificationService] No preferences loaded, cannot determine quiet hours")
            return false
        }

        let hour = Calendar.current.component(.hour, from: Date())

        // Check quiet hours
        // quietHoursStart = when quiet hours BEGIN (e.g., 22 = 10 PM)
        // quietHoursEnd = when quiet hours END (e.g., 8 = 8 AM)
        if prefs.quietHoursStart < prefs.quietHoursEnd {
            // Daytime quiet hours (e.g., start=10, end=22 means quiet from 10am-10pm)
            // Can send when hour < start OR hour >= end
            return hour < prefs.quietHoursStart || hour >= prefs.quietHoursEnd
        } else {
            // Overnight quiet hours (e.g., start=22, end=8 means quiet from 10pm-8am)
            // Can send when hour >= end AND hour < start (i.e., 8am-10pm)
            return hour >= prefs.quietHoursEnd && hour < prefs.quietHoursStart
        }
    }

    private func getTodayNotificationCount(userId: String) async -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        let todayISO = ISO8601DateFormatter().string(from: today)

        let sql = """
            SELECT COUNT(*) as count
            FROM notification_history
            WHERE user_id = ? AND sent_at >= ?
        """

        guard let rows = try? await sqliteService.queryRaw(sql, parameters: [userId, todayISO]),
              let count = rows.first?["count"] as? Int else {
            return 0
        }

        return count
    }

    private func hasNotificationBeenSent(userId: String, type: NotificationType, contentId: String) async -> Bool {
        let sql = """
            SELECT COUNT(*) as count
            FROM notification_history
            WHERE user_id = ? AND notification_type = ? AND content_id = ?
        """

        guard let rows = try? await sqliteService.queryRaw(sql, parameters: [userId, type.rawValue, contentId]),
              let count = rows.first?["count"] as? Int else {
            return false
        }

        return count > 0
    }

    private func recordNotificationSent(userId: String, type: NotificationType, contentId: String) async {
        let sql = """
            INSERT INTO notification_history (id, user_id, notification_type, content_id, sent_at, clicked, dismissed)
            VALUES (?, ?, ?, ?, ?, 0, 0)
        """

        _ = try? await sqliteService.queryRaw(sql, parameters: [
            UUID().uuidString,
            userId,
            type.rawValue,
            contentId,
            ISO8601DateFormatter().string(from: Date())
        ])
    }

    private func getWatchingShows(userId: String) async -> [TVShowSummary] {
        // Get shows from watchlist
        let sql = """
            SELECT DISTINCT media_id, media_type
            FROM list_items
            WHERE user_id = ? AND media_type = 'tv' AND deleted_at IS NULL
        """

        guard let rows = try? await sqliteService.queryRaw(sql, parameters: [userId]) else {
            return []
        }

        return rows.compactMap { row in
            guard let id = row["media_id"] as? Int else { return nil }
            return TVShowSummary(id: id, title: "") // Will fetch full details from TMDB
        }
    }

    private func getLastWatchedEpisode(userId: String, showId: Int) async -> EpisodeIdentifier {
        let sql = """
            SELECT season_number, episode_number
            FROM user_clip_history
            WHERE user_id = ? AND media_id = ? AND media_type = 'tv'
            ORDER BY watched_at DESC
            LIMIT 1
        """

        guard let rows = try? await sqliteService.queryRaw(sql, parameters: [userId, showId]),
              let row = rows.first,
              let season = row["season_number"] as? Int,
              let episode = row["episode_number"] as? Int else {
            return EpisodeIdentifier(seasonNumber: 0, episodeNumber: 0)
        }

        return EpisodeIdentifier(seasonNumber: season, episodeNumber: episode)
    }

    private func findNextEpisode(show: TVShow, after lastWatched: EpisodeIdentifier) -> EpisodeDetails? {
        // Episode-level data requires season endpoints; skip until we fetch season details.
        return nil
    }

    private func calculatePersonalizationScore(movie: Movie, userProfile: UserProfile) -> Double {
        var score = 0.0

        // Genre match
        let genreMatches = (movie.genreIds ?? []).filter { genreId in
            userProfile.topGenres.contains { $0.genreId == genreId }
        }
        score += Double(genreMatches.count) * 15.0

        // Quality
        score += movie.voteAverage * 2.0

        // Popularity
        score += min(movie.popularity / 100.0, 10.0)

        return score
    }

    private func loadAndReturnPreferences(userId: String) async -> NotificationPreferences? {
        await loadPreferences(userId: userId)
        return preferences
    }

    private func parseJSONArray(_ jsonString: String?) -> [Int] {
        guard let jsonString = jsonString,
              let data = jsonString.data(using: .utf8),
              let array = try? JSONDecoder().decode([Int].self, from: data) else {
            return []
        }
        return array
    }

    // MARK: - Pro Feature: Custom Alert Registration

    /// Register custom actor alerts for Pro users
    /// Saves actor subscriptions to local database and queues sync to Supabase
    func registerActorAlerts(userId: String, actorIds: [Int]) async {
        Logger.info("[SmartNotificationService] Registering \(actorIds.count) actor alerts for user: \(userId)")

        // First, delete existing actor subscriptions for this user
        let deleteSql = """
            DELETE FROM notification_subscriptions
            WHERE user_id = ? AND type = 'actor_alert'
        """
        _ = sqliteService.execute(deleteSql, parameters: [userId])

        // Insert new actor subscriptions
        let now = ISO8601DateFormatter().string(from: Date())

        for actorId in actorIds {
            let subscriptionId = UUID().uuidString.lowercased()

            let insertSql = """
                INSERT INTO notification_subscriptions (
                    id, user_id, actor_id, genre_id, type, created_at, synced_at
                ) VALUES (?, ?, ?, NULL, 'actor_alert', ?, NULL)
            """

            let success = sqliteService.execute(insertSql, parameters: [
                subscriptionId,
                userId,
                actorId,
                now
            ])

            if success {
                // Queue sync to Supabase
                let record: [String: Any] = [
                    "id": subscriptionId,
                    "user_id": userId,
                    "actor_id": actorId,
                    "genre_id": NSNull(),
                    "type": "actor_alert",
                    "created_at": now
                ]

                do {
                    try await SyncEngine.shared.queueOperation(
                        table: "notification_subscriptions",
                        operationType: "UPSERT",
                        recordId: subscriptionId,
                        payload: record,
                        dependsOn: nil
                    )
                } catch {
                    Logger.error("[SmartNotificationService] Failed to queue actor alert sync: \(error)")
                }

                Logger.debug("[SmartNotificationService] Registered actor alert for actor ID: \(actorId)")
            } else {
                Logger.error("[SmartNotificationService] Failed to insert actor alert for actor ID: \(actorId)")
            }
        }

        Logger.info("[SmartNotificationService] Completed registering actor alerts")
    }

    /// Register custom genre alerts for Pro users
    /// Saves genre subscriptions to local database and queues sync to Supabase
    func registerGenreAlerts(userId: String, genreIds: [Int]) async {
        Logger.info("[SmartNotificationService] Registering \(genreIds.count) genre alerts for user: \(userId)")

        // First, delete existing genre subscriptions for this user
        let deleteSql = """
            DELETE FROM notification_subscriptions
            WHERE user_id = ? AND type = 'genre_alert'
        """
        _ = sqliteService.execute(deleteSql, parameters: [userId])

        // Insert new genre subscriptions
        let now = ISO8601DateFormatter().string(from: Date())

        for genreId in genreIds {
            let subscriptionId = UUID().uuidString.lowercased()

            let insertSql = """
                INSERT INTO notification_subscriptions (
                    id, user_id, actor_id, genre_id, type, created_at, synced_at
                ) VALUES (?, ?, NULL, ?, 'genre_alert', ?, NULL)
            """

            let success = sqliteService.execute(insertSql, parameters: [
                subscriptionId,
                userId,
                genreId,
                now
            ])

            if success {
                // Queue sync to Supabase
                let record: [String: Any] = [
                    "id": subscriptionId,
                    "user_id": userId,
                    "actor_id": NSNull(),
                    "genre_id": genreId,
                    "type": "genre_alert",
                    "created_at": now
                ]

                do {
                    try await SyncEngine.shared.queueOperation(
                        table: "notification_subscriptions",
                        operationType: "UPSERT",
                        recordId: subscriptionId,
                        payload: record,
                        dependsOn: nil
                    )
                } catch {
                    Logger.error("[SmartNotificationService] Failed to queue genre alert sync: \(error)")
                }

                Logger.debug("[SmartNotificationService] Registered genre alert for genre ID: \(genreId)")
            } else {
                Logger.error("[SmartNotificationService] Failed to insert genre alert for genre ID: \(genreId)")
            }
        }

        Logger.info("[SmartNotificationService] Completed registering genre alerts")
    }

    /// Load custom alert subscriptions from database
    /// Used to populate preferences when loading
    func loadCustomAlertSubscriptions(userId: String) async -> (actorIds: [Int], genreIds: [Int]) {
        var actorIds: [Int] = []
        var genreIds: [Int] = []

        // Load actor alerts
        let actorSql = """
            SELECT actor_id FROM notification_subscriptions
            WHERE user_id = ? AND type = 'actor_alert' AND actor_id IS NOT NULL
        """

        if let actorRows = try? await sqliteService.queryRaw(actorSql, parameters: [userId]) {
            actorIds = actorRows.compactMap { $0["actor_id"] as? Int }
        }

        // Load genre alerts
        let genreSql = """
            SELECT genre_id FROM notification_subscriptions
            WHERE user_id = ? AND type = 'genre_alert' AND genre_id IS NOT NULL
        """

        if let genreRows = try? await sqliteService.queryRaw(genreSql, parameters: [userId]) {
            genreIds = genreRows.compactMap { $0["genre_id"] as? Int }
        }

        Logger.debug("[SmartNotificationService] Loaded custom alerts: \(actorIds.count) actors, \(genreIds.count) genres")
        return (actorIds, genreIds)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension SmartNotificationService: @MainActor UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Handle notification tap
        let userInfo = response.notification.request.content.userInfo

        Task {
            await handleNotificationTap(userInfo: userInfo)
        }

        completionHandler()
    }

    private func handleNotificationTap(userInfo: [AnyHashable: Any]) async {
        guard let type = userInfo["type"] as? String else {
            Logger.warning("[SmartNotificationService] Notification tap missing 'type' key — ignoring")
            return
        }
        Logger.info("[SmartNotificationService] Notification tapped: \(type)")

        await MainActor.run {
            let manager = AppNavigationManager.shared
            manager.handle(userInfo: userInfo)

            // Fallback: no valid media_id/media_type in payload → navigate to Discovery tab
            if manager.deepLinkTarget == nil {
                NotificationCenter.default.post(name: .navigateToDiscoveryTab, object: nil)
            }
        }
    }
}

// MARK: - Data Models

struct NotificationPreferences: Codable {
    var enableNewEpisodes: Bool = true
    var enableReleaseAlerts: Bool = true
    var enableActorAlerts: Bool = true
    var enableSimilarContent: Bool = true
    var enableWatchlistAlerts: Bool = true
    var enableMilestones: Bool = true

    var maxDailyNotifications: Int = 3
    var quietHoursStart: Int = 22 // 10 PM
    var quietHoursEnd: Int = 8    // 8 AM

    var customActorAlerts: [Int] = []
    var customGenreAlerts: [Int] = []
}

enum NotificationType: String, Codable {
    case newEpisode = "new_episode"
    case releaseAlert = "release_alert"
    case actorAlert = "actor_alert"
    case similarContent = "similar_content"
    case watchlistAlert = "watchlist_alert"
    case milestone = "milestone"
}

struct NewEpisodeNotification {
    let show: TVShowSummary
    let episode: EpisodeDetails
}

struct ReleaseNotification {
    let movie: Movie
    let matchReason: String
}

struct ActorNotification {
    let actor: ActorPreference
    let movie: Movie
}

struct SimilarContentNotification {
    let originalMovie: MediaSummary
    let similarMovie: Movie
}

struct WatchlistNotification {
    let mediaId: Int
    let title: String
    let message: String
}

struct MilestoneNotification {
    let type: MilestoneType
    let title: String
    let message: String
}

enum MilestoneType {
    case watchCount(Int)
    case watchStreak(Int)
}

struct TVShowSummary {
    let id: Int
    let title: String
}

struct EpisodeIdentifier {
    let seasonNumber: Int
    let episodeNumber: Int
}

struct EpisodeDetails {
    let seasonNumber: Int
    let episodeNumber: Int
    let name: String
    let airDate: Date
}

struct TVShowDetails {
    let id: Int
    let title: String
    let seasons: [SeasonDetails]
}

struct SeasonDetails {
    let seasonNumber: Int
    let episodes: [EpisodeDetails]
}
