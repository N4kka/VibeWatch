import XCTest
import Combine
@testable import VibeWatchApp

/// Tests for AnalyticsInsightsService mood analysis.
///
/// After ARCH-001 (strada B) the dashboard reads real data: mood is derived from the genres of the
/// items in the user's "seen" list (list_items joined to a lists row of type 'seen'), mapped through
/// a genre→mood table. It was previously read from user_clip_history / user_preferences, neither of
/// which the app populates. The threshold for a non-empty distribution is 5 *distinct* genres.
@MainActor
final class AnalyticsInsightsTests: XCTestCase {

    let userId = "test-user-mood-\(UUID().uuidString)"
    private let seenListId = "seen-list-\(UUID().uuidString)"

    override func setUp() async throws {
        try await super.setUp()
        let db = SQLiteService.shared
        _ = db.execute(
            "INSERT OR IGNORE INTO profiles (id, display_name) VALUES (?, 'Test User')",
            parameters: [userId]
        )
        // A "seen" list for this user — the real source the analytics now read.
        _ = db.execute(
            "INSERT OR REPLACE INTO lists (id, user_id, name, type) VALUES (?, ?, 'Seen', 'seen')",
            parameters: [seenListId, userId]
        )
        cleanItems()
    }

    override func tearDown() async throws {
        let db = SQLiteService.shared
        cleanItems()
        _ = db.execute("DELETE FROM lists WHERE id = ?", parameters: [seenListId])
        _ = db.execute("DELETE FROM profiles WHERE id = ?", parameters: [userId])
        try await super.tearDown()
    }

    private func cleanItems() {
        _ = SQLiteService.shared.execute("DELETE FROM list_items WHERE list_id = ?", parameters: [seenListId])
    }

    /// Adds an item to the seen list with the given TMDB genre ids (stored as a JSON array string,
    /// exactly as list_items.genres holds them).
    private func seedSeenItem(mediaId: Int, genres: [Int]) {
        let genresJSON = "[" + genres.map(String.init).joined(separator: ",") + "]"
        _ = SQLiteService.shared.execute("""
            INSERT INTO list_items (id, list_id, user_id, media_id, media_type, title, genres, added_at)
            VALUES (?, ?, ?, ?, 'movie', ?, ?, datetime('now'))
        """, parameters: [
            "item-\(mediaId)-\(userId)", seenListId, userId, mediaId, "Movie \(mediaId)", genresJSON
        ])
    }

    func testGenerateUserStatisticsMoodAnalysisIsNotNil() async throws {
        let stats = await AnalyticsInsightsService.shared.generateUserStatistics(
            userId: userId, timeframe: .allTime
        )
        XCTAssertNotNil(stats, "generateUserStatistics must return a non-nil UserStatistics")
        XCTAssertNotNil(stats?.moodAnalysis, "generateUserStatistics must return non-nil moodAnalysis")
    }

    /// With ≥5 distinct genres in the seen list, the mood distribution reflects them.
    func testMoodDistributionReflectsGenreHistory() async throws {
        // 5 distinct genres so the distribution is computed (not the placeholder):
        // 35→Light, 28→Intense, plus 18/99/36 (Thoughtful) to clear the distinct-genre threshold.
        seedSeenItem(mediaId: 1, genres: [35])   // Light
        seedSeenItem(mediaId: 2, genres: [35])   // Light
        seedSeenItem(mediaId: 3, genres: [28])   // Intense
        seedSeenItem(mediaId: 4, genres: [18])   // Thoughtful
        seedSeenItem(mediaId: 5, genres: [99])   // Thoughtful
        seedSeenItem(mediaId: 6, genres: [36])   // Thoughtful

        let stats = await AnalyticsInsightsService.shared.generateUserStatistics(
            userId: userId, timeframe: .allTime
        )
        let dist = stats?.moodAnalysis?.moodDistribution ?? [:]
        XCTAssertNotNil(dist["Light"], "Light mood expected from comedy genre id (35)")
        XCTAssertNotNil(dist["Intense"], "Intense mood expected from action genre id (28)")
    }

    /// Below 5 distinct genres, moodAnalysis is non-nil but its distribution is empty (placeholder).
    func testMoodDistributionIsEmptyWhenInsufficientHistory() async throws {
        seedSeenItem(mediaId: 1, genres: [35])
        seedSeenItem(mediaId: 2, genres: [28])   // only 2 distinct genres

        let stats = await AnalyticsInsightsService.shared.generateUserStatistics(
            userId: userId, timeframe: .allTime
        )
        XCTAssertNotNil(stats?.moodAnalysis,
            "moodAnalysis must be non-nil even when history is insufficient")
        XCTAssertTrue(stats?.moodAnalysis?.moodDistribution.isEmpty ?? false,
            "moodDistribution must be empty (not absent) below the distinct-genre threshold")
    }

    /// If the tracking mirror is temporarily unreadable (migration/corrupt cache), authenticated
    /// analytics must fall back to the legacy TV rows. Excluding them before knowing that the
    /// derived read succeeded turns both lists into zero and silently falsifies completion.
    func testWatchStatsFallBackToLegacyTVRowsWhenTrackingMirrorReadFails() async throws {
        let path = NSTemporaryDirectory() + "vibewatch_analytics_fallback_\(UUID().uuidString).sqlite"
        var sqlite: SQLiteService? = SQLiteService(dbPath: path)
        var service: AnalyticsInsightsService?
        defer {
            service = nil
            sqlite = nil
            try? FileManager.default.removeItem(atPath: path)
        }

        let fallbackUserId = "analytics-fallback-\(UUID().uuidString)"
        let fallbackSeenId = "fallback-seen-\(UUID().uuidString)"
        let fallbackWatchlistId = "fallback-watchlist-\(UUID().uuidString)"
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO profiles (id, display_name) VALUES (?, 'Fallback')",
            parameters: [fallbackUserId]
        ))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO lists (id, user_id, name, type) VALUES (?, ?, 'Seen', 'seen')",
            parameters: [fallbackSeenId, fallbackUserId]
        ))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO lists (id, user_id, name, type) VALUES (?, ?, 'Watchlist', 'watchlist')",
            parameters: [fallbackWatchlistId, fallbackUserId]
        ))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO list_items (id, list_id, user_id, media_id, media_type, title) VALUES (?, ?, ?, 301, 'tv', 'Seen TV')",
            parameters: ["fallback-seen-item", fallbackSeenId, fallbackUserId]
        ))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO list_items (id, list_id, user_id, media_id, media_type, title) VALUES (?, ?, ?, 302, 'tv', 'Queued TV')",
            parameters: ["fallback-watchlist-item", fallbackWatchlistId, fallbackUserId]
        ))
        XCTAssertTrue(sqlite!.execute("DROP TABLE tv_tracking"))

        let auth = AnalyticsAuthStub(user: User(id: fallbackUserId, email: "fallback@example.com"))
        service = AnalyticsInsightsService(sqliteService: sqlite!, authService: auth)
        let stats = await service!.calculateWatchStats(userId: fallbackUserId, timeframe: .allTime)

        XCTAssertEqual(stats.completionRate, 0.5, accuracy: 0.0001,
            "one legacy TV seen out of two tracked TV titles must remain visible during mirror failure")
    }
}

@MainActor
final class UserPreferenceTrackingFusionTests: XCTestCase {
    /// RecentActivity.watchlist feeds "Continue Your Journey": it must contain only the actual
    /// watchlist, merge movies from list_items with TV from the tracking mirror, and never leak
    /// seen/custom rows or the hidden legacy copy of an authenticated TV row.
    func testRecentWatchlistUsesDerivedTVAndOnlyActualWatchlistMovies() async throws {
        let path = NSTemporaryDirectory() + "vibewatch_preferences_fusion_\(UUID().uuidString).sqlite"
        var sqlite: SQLiteService? = SQLiteService(dbPath: path)
        var manager: UserPreferenceManager?
        defer {
            manager = nil
            sqlite = nil
            try? FileManager.default.removeItem(atPath: path)
        }

        let userId = "preferences-fusion-\(UUID().uuidString)"
        let watchlistId = "preferences-watchlist-\(UUID().uuidString)"
        let seenId = "preferences-seen-\(UUID().uuidString)"
        let customId = "preferences-custom-\(UUID().uuidString)"
        XCTAssertTrue(sqlite!.execute("INSERT INTO profiles (id) VALUES (?)", parameters: [userId]))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO lists (id, user_id, name, type) VALUES (?, ?, 'Watchlist', 'watchlist')",
            parameters: [watchlistId, userId]
        ))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO lists (id, user_id, name, type) VALUES (?, ?, 'Seen', 'seen')",
            parameters: [seenId, userId]
        ))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO lists (id, user_id, name, type) VALUES (?, ?, 'Custom', 'custom')",
            parameters: [customId, userId]
        ))

        func seedItem(_ id: String, listId: String, mediaId: Int, type: String, title: String) {
            XCTAssertTrue(sqlite!.execute(
                "INSERT INTO list_items (id, list_id, user_id, media_id, media_type, title, added_at) VALUES (?, ?, ?, ?, ?, ?, '2026-08-01T10:00:00Z')",
                parameters: [id, listId, userId, mediaId, type, title]
            ))
        }
        seedItem("movie-watchlist", listId: watchlistId, mediaId: 101, type: "movie", title: "Queued movie")
        seedItem("legacy-tv-watchlist", listId: watchlistId, mediaId: 301, type: "tv", title: "Hidden legacy TV")
        seedItem("movie-seen", listId: seenId, mediaId: 102, type: "movie", title: "Seen movie")
        seedItem("movie-custom", listId: customId, mediaId: 103, type: "movie", title: "Custom movie")

        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO tv_tracking (user_id, tmdb_show_id, bucket, show_name, updated_at) VALUES (?, 401, 'not_started', 'Queued TV', '2026-08-02T10:00:00Z')",
            parameters: [userId]
        ))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO tv_tracking (user_id, tmdb_show_id, bucket, show_name, completed_at, updated_at) VALUES (?, 402, 'up_to_date', 'Seen TV', '2026-08-02T11:00:00Z', '2026-08-02T11:00:00Z')",
            parameters: [userId]
        ))

        let auth = AnalyticsAuthStub(user: User(id: userId, email: "preferences@example.com"))
        manager = UserPreferenceManager(
            sqliteService: sqlite!,
            supabaseClient: .shared,
            authService: auth
        )

        let profile = await manager!.aggregatePreferences()
        let keys = Set(profile.recentActivity.watchlist.map { "\($0.mediaType.rawValue):\($0.id)" })

        XCTAssertEqual(keys, ["movie:101", "tv:401"])
    }

    /// If the tracking mirror cannot be queried, legacy TV rows remain the only recoverable
    /// watchlist source. They must not be hidden until the derived read has actually succeeded.
    func testRecentWatchlistFallsBackToLegacyTVWhenTrackingMirrorReadFails() async throws {
        let path = NSTemporaryDirectory() + "vibewatch_preferences_fallback_\(UUID().uuidString).sqlite"
        var sqlite: SQLiteService? = SQLiteService(dbPath: path)
        var manager: UserPreferenceManager?
        defer {
            manager = nil
            sqlite = nil
            try? FileManager.default.removeItem(atPath: path)
        }

        let userId = "preferences-fallback-\(UUID().uuidString)"
        let watchlistId = "preferences-fallback-watchlist-\(UUID().uuidString)"
        XCTAssertTrue(sqlite!.execute("INSERT INTO profiles (id) VALUES (?)", parameters: [userId]))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO lists (id, user_id, name, type) VALUES (?, ?, 'Watchlist', 'watchlist')",
            parameters: [watchlistId, userId]
        ))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO list_items (id, list_id, user_id, media_id, media_type, title) VALUES (?, ?, ?, 501, 'tv', 'Legacy queued TV')",
            parameters: ["legacy-tv", watchlistId, userId]
        ))
        XCTAssertTrue(sqlite!.execute("DROP TABLE tv_tracking"))

        let auth = AnalyticsAuthStub(user: User(id: userId, email: "fallback@example.com"))
        manager = UserPreferenceManager(
            sqliteService: sqlite!,
            supabaseClient: .shared,
            authService: auth
        )

        let profile = await manager!.aggregatePreferences()

        XCTAssertEqual(profile.recentActivity.watchlist.count, 1)
        XCTAssertEqual(profile.recentActivity.watchlist.first?.id, 501)
        XCTAssertEqual(profile.recentActivity.watchlist.first?.mediaType, .tv)
    }

    /// The Continue Journey carousel must ask TMDB's TV endpoint for TV summaries. Calling the
    /// movie endpoint with the same numeric id can return unrelated content or nothing at all.
    func testContinueJourneyRoutesLookupsByMediaType() async {
        var movieLookups: [Int] = []
        var tvLookups: [Int] = []

        _ = await DiscoveryPersonalizationService.resolveJourneyItem(
            MediaSummary(id: 601, title: "Queued show", mediaType: .tv),
            movieLookup: { id in
                movieLookups.append(id)
                return nil
            },
            tvLookup: { id in
                tvLookups.append(id)
                return nil
            }
        )
        _ = await DiscoveryPersonalizationService.resolveJourneyItem(
            MediaSummary(id: 602, title: "Queued movie", mediaType: .movie),
            movieLookup: { id in
                movieLookups.append(id)
                return nil
            },
            tvLookup: { id in
                tvLookups.append(id)
                return nil
            }
        )

        XCTAssertEqual(movieLookups, [602])
        XCTAssertEqual(tvLookups, [601])
    }

    /// The ten-item cap applies after merging the two stores. Otherwise ten old TV rows consume
    /// the cap before a newer movie from the real watchlist is even considered.
    func testRecentWatchlistAppliesLimitAfterGlobalRecencySort() async throws {
        let path = NSTemporaryDirectory() + "vibewatch_preferences_order_\(UUID().uuidString).sqlite"
        var sqlite: SQLiteService? = SQLiteService(dbPath: path)
        var manager: UserPreferenceManager?
        defer {
            manager = nil
            sqlite = nil
            try? FileManager.default.removeItem(atPath: path)
        }

        let userId = "preferences-order-\(UUID().uuidString)"
        let watchlistId = "preferences-order-watchlist-\(UUID().uuidString)"
        XCTAssertTrue(sqlite!.execute("INSERT INTO profiles (id) VALUES (?)", parameters: [userId]))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO lists (id, user_id, name, type) VALUES (?, ?, 'Watchlist', 'watchlist')",
            parameters: [watchlistId, userId]
        ))
        XCTAssertTrue(sqlite!.execute(
            "INSERT INTO list_items (id, list_id, user_id, media_id, media_type, title, added_at) VALUES ('new-movie', ?, ?, 699, 'movie', 'Newest movie', '2026-08-02T12:00:00Z')",
            parameters: [watchlistId, userId]
        ))
        for offset in 0..<10 {
            XCTAssertTrue(sqlite!.execute(
                "INSERT INTO tv_tracking (user_id, tmdb_show_id, bucket, show_name, updated_at) VALUES (?, ?, 'not_started', ?, '2026-08-01T12:00:00Z')",
                parameters: [userId, 700 + offset, "Old TV \(offset)"]
            ))
        }

        let auth = AnalyticsAuthStub(user: User(id: userId, email: "order@example.com"))
        manager = UserPreferenceManager(
            sqliteService: sqlite!,
            supabaseClient: .shared,
            authService: auth
        )

        let watchlist = await manager!.aggregatePreferences().recentActivity.watchlist

        XCTAssertEqual(watchlist.count, 10)
        XCTAssertTrue(watchlist.contains { $0.id == 699 && $0.mediaType == .movie })
    }
}

@MainActor
private final class AnalyticsAuthStub: AuthStatusProviding {
    var currentUser: User?
    private let subject: CurrentValueSubject<Bool, Never>

    init(user: User?) {
        self.currentUser = user
        self.subject = CurrentValueSubject(user != nil)
    }

    var isAuthenticatedPublisher: AnyPublisher<Bool, Never> {
        subject.eraseToAnyPublisher()
    }
}
