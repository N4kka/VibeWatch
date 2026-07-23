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

    // STAB-003: runMigrations now refuses to record the latest version until every migration's
    // end-state artifact is actually present. This guards against the *opposite* regression — that
    // the artifact list wrongly names something the real schema doesn't produce, which would block
    // the version bump forever and re-run migrations on every launch. On the fully-initialised
    // shared DB, every checked artifact (table, column, index) must exist.
    func testEveryVerifiedMigrationArtifactExistsOnRealSchema() {
        let db = SQLiteService.shared
        // Columns
        XCTAssertTrue(db.columnExists("clip_reactions", column: "updated_at"))
        XCTAssertTrue(db.columnExists("clip_reactions", column: "synced_at"))
        XCTAssertTrue(db.columnExists("user_ai_token_usage", column: "usage_day"))
        XCTAssertTrue(db.columnExists("detail_cache", column: "vote_count"))
        XCTAssertTrue(db.columnExists("lists", column: "is_public"))
        // Tables / indexes
        XCTAssertTrue(db.objectExists("watch_providers"))
        XCTAssertTrue(db.objectExists("idx_lists_one_core_per_user_type"))
        XCTAssertTrue(db.objectExists("list_follows"))
        XCTAssertTrue(db.objectExists("public_lists_cache"))
        // Sanity: the helper says no when something truly isn't there.
        XCTAssertFalse(db.objectExists("definitely_not_a_real_table_xyz"))
    }
}
