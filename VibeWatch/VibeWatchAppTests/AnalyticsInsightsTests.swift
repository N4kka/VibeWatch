import XCTest
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
}
