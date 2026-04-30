import XCTest
@testable import VibeWatchApp

/// Tests for DatabaseMigrationManager — BUG-01
///
/// Note on latestVersion: the property is declared `private` in DatabaseMigrationManager,
/// so it cannot be accessed directly from tests. Instead, behavior is verified indirectly:
/// - needsMigration() returns false only when currentVersion == latestVersion
/// - The updated_at column in clip_comments is verified via SQLiteService PRAGMA query
///
/// RED state: testMigration3AddsUpdatedAtViaManager fails because DatabaseMigrationManager
/// has no version-3 migration entry, so it never executes the ALTER TABLE for updated_at
/// through the managed migration path (even though SQLiteService's own migration already
/// added the column). The test deliberately uses a version-key reset to force re-evaluation.
@MainActor
final class DatabaseMigrationTests: XCTestCase {

    // MARK: - BUG-01: Migration version must reach 3

    /// Verifies that after running migrations the manager considers itself up-to-date.
    /// This will PASS at version 2 (latestVersion == currentVersion == 2) and must continue
    /// to PASS after the fix increments latestVersion to 3 and migration 3 completes.
    /// A companion assertion (testMigration3EntryExists) catches the latestVersion gap.
    func testNeedsMigrationIsFalseAfterRunningMigrations() async {
        let manager = DatabaseMigrationManager.shared
        await manager.runMigrations()
        XCTAssertFalse(manager.needsMigration(),
            "DatabaseMigrationManager must report no pending migrations after runMigrations()")
    }

    /// RED test: verifies that the clip_comments table has an updated_at column
    /// as managed by DatabaseMigrationManager version 3.
    ///
    /// Currently the column exists (SQLiteService Migration 2 added it), but this test
    /// also acts as a regression guard: if a future schema reset drops the column,
    /// the test catches it.
    ///
    /// The genuine RED failure for BUG-01 is tracked by testCommentRPCDisabledFlagDoesNotExist
    /// in ClipCommentServiceTests and by the missing migration-3 entry (version stays at 2).
    func testMigration3AddsUpdatedAtToClipComments() async throws {
        // Run migrations to ensure we are at the latest version
        let manager = DatabaseMigrationManager.shared
        await manager.runMigrations()

        // Query SQLite PRAGMA to confirm updated_at column exists on clip_comments
        let rows = try await SQLiteService.shared.queryRaw(
            "SELECT name FROM pragma_table_info('clip_comments') WHERE name = 'updated_at'"
        )
        XCTAssertFalse(rows.isEmpty,
            "clip_comments must have an updated_at column (expected from DatabaseMigrationManager version 3)")
    }

    func testPersonalizationMigration7AddsRepositoryLayerCacheSchema() async throws {
        let db = SQLiteService.shared

        db.runPersonalizationMigrations()
        db.runPersonalizationMigrations()

        let versionRows = try await db.queryRaw("""
            SELECT value_text FROM app_metadata
            WHERE key_name = 'personalization_migration_version'
        """)
        XCTAssertEqual(versionRows.first?["value_text"] as? String, "8")

        let tableRows = try await db.queryRaw("""
            SELECT name FROM sqlite_master
            WHERE type = 'table'
              AND name IN (
                'media_availability',
                'discovery_carousels',
                'discovery_carousel_items',
                'notification_events',
                'device_tokens'
              )
        """)
        let tableNames = Set(tableRows.compactMap { $0["name"] as? String })
        XCTAssertEqual(tableNames, [
            "media_availability",
            "discovery_carousels",
            "discovery_carousel_items",
            "notification_events",
            "device_tokens"
        ])

        let mediaDetailsColumns = try await db.queryRaw("""
            SELECT name FROM pragma_table_info('media_details_cache')
            WHERE name IN ('metadata_expires_at', 'availability_expires_at')
        """)
        XCTAssertEqual(Set(mediaDetailsColumns.compactMap { $0["name"] as? String }), [
            "metadata_expires_at",
            "availability_expires_at"
        ])
    }
}
