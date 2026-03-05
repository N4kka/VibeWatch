import XCTest
@testable import VibeWatchApp

/// Tests for AnalyticsInsightsService mood analysis — BUG-04
///
/// Current state: generateUserStatistics() returns moodAnalysis: nil (hardcoded).
/// After BUG-04 fix: moodAnalysis is computed from viewing history genre patterns.
///
/// Schema note: user_clip_history does not currently have a genre_ids column.
/// BUG-04 implementation must add this column (via DatabaseMigrationManager version 3
/// or the corresponding DatabaseMigrationManager entry) and populate it when recording
/// clip views. The distribution tests seed genre_ids once that column exists.
@MainActor
final class AnalyticsInsightsTests: XCTestCase {

    let userId = "test-user-mood-\(UUID().uuidString)"

    override func setUp() async throws {
        try await super.setUp()
        // Ensure any prior test data for this userId is removed
        _ = SQLiteService.shared.execute(
            "DELETE FROM user_clip_history WHERE user_id = ?",
            parameters: [userId]
        )
    }

    override func tearDown() async throws {
        _ = SQLiteService.shared.execute(
            "DELETE FROM user_clip_history WHERE user_id = ?",
            parameters: [userId]
        )
        try await super.tearDown()
    }

    // MARK: - BUG-04: moodAnalysis must not be nil

    /// RED test: generateUserStatistics must return a non-nil moodAnalysis.
    /// Currently FAILS because the service hardcodes moodAnalysis: nil at line 48.
    func testGenerateUserStatisticsMoodAnalysisIsNotNil() async throws {
        let stats = await AnalyticsInsightsService.shared.generateUserStatistics(
            userId: userId,
            timeframe: .allTime
        )
        XCTAssertNotNil(stats,
            "generateUserStatistics must return a non-nil UserStatistics")
        XCTAssertNotNil(stats?.moodAnalysis,
            "generateUserStatistics must return non-nil moodAnalysis after BUG-04 fix")
    }

    // MARK: - BUG-04: Distribution from genre history

    /// Verifies moodDistribution contains expected mood keys when genre history is present.
    /// Requires genre_ids column to exist on user_clip_history (added during BUG-04 implementation).
    /// Will produce empty distribution until that column and the calculateMoodAnalysis logic exist.
    func testMoodDistributionReflectsGenreHistory() async throws {
        let db = SQLiteService.shared

        // Check whether genre_ids column exists; if not, this test is a pre-condition stub
        let genreColExists = db.columnExists("user_clip_history", column: "genre_ids")

        guard genreColExists else {
            // genre_ids column does not exist yet — BUG-04 implementation must add it.
            // Test is recorded as skipped until the column exists.
            throw XCTSkip("genre_ids column not yet present on user_clip_history — add in BUG-04 GREEN phase")
        }

        // Seed 5 comedy (genre 35 → Light) and 5 action (genre 28 → Intense) rows
        for i in 0..<5 {
            _ = db.execute("""
                INSERT INTO user_clip_history
                    (id, user_id, device_id, clip_id, genre_ids, watched_at)
                VALUES (?, ?, 'test-device', ?, '35', datetime('now'))
            """, parameters: [
                "test-comedy-\(i)-\(userId)", userId, "clip-comedy-\(i)-\(userId)"
            ])
        }
        for i in 0..<5 {
            _ = db.execute("""
                INSERT INTO user_clip_history
                    (id, user_id, device_id, clip_id, genre_ids, watched_at)
                VALUES (?, ?, 'test-device', ?, '28', datetime('now'))
            """, parameters: [
                "test-action-\(i)-\(userId)", userId, "clip-action-\(i)-\(userId)"
            ])
        }

        let stats = await AnalyticsInsightsService.shared.generateUserStatistics(
            userId: userId,
            timeframe: .allTime
        )
        let dist = stats?.moodAnalysis?.moodDistribution ?? [:]
        XCTAssertNotNil(dist["Light"], "Light mood expected from comedy genre IDs (35)")
        XCTAssertNotNil(dist["Intense"], "Intense mood expected from action genre IDs (28)")
    }

    // MARK: - BUG-04: Empty state returns non-nil moodAnalysis with empty distribution

    /// Verifies that with fewer than 5 history items, moodAnalysis is non-nil but
    /// moodDistribution is empty (empty-state path, not nil-state).
    /// Will pass/fail depending on BUG-04 implementation threshold logic.
    func testMoodDistributionIsEmptyWhenInsufficientHistory() async throws {
        let db = SQLiteService.shared
        let genreColExists = db.columnExists("user_clip_history", column: "genre_ids")

        // Seed only 2 rows (below threshold of 5)
        if genreColExists {
            for i in 0..<2 {
                _ = db.execute("""
                    INSERT INTO user_clip_history
                        (id, user_id, device_id, clip_id, genre_ids, watched_at)
                    VALUES (?, ?, 'test-device', ?, '35', datetime('now'))
                """, parameters: [
                    "test-few-\(i)-\(userId)", userId, "clip-few-\(i)-\(userId)"
                ])
            }
        }

        let stats = await AnalyticsInsightsService.shared.generateUserStatistics(
            userId: userId,
            timeframe: .allTime
        )
        XCTAssertNotNil(stats?.moodAnalysis,
            "moodAnalysis must be non-nil even when history is insufficient for mood computation")
        XCTAssertTrue(stats?.moodAnalysis?.moodDistribution.isEmpty ?? false,
            "moodDistribution must be empty (not absent) when fewer than 5 history items exist")
    }
}
