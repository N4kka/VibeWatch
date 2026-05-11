import Foundation
import SQLite3

/// Unified database migration manager
/// Consolidates schema migrations, personalization migrations, and data migrations into a single system
///
/// Phase 4: Database & Performance - Unify Migration Systems
@MainActor
final class DatabaseMigrationManager {
    static let shared = DatabaseMigrationManager()

    private let db = SQLiteService.shared
    private let supabase = SupabaseService.shared

    /// Migration version key in app_metadata table
    private let versionKey = "unified_migration_version"

    /// Current latest migration version
    private let latestVersion = 5

    private init() {}

    // MARK: - Public API

    /// Run all pending migrations
    /// Call this once during app initialization
    func runMigrations() async {
        let currentVersion = getCurrentVersion()

        guard currentVersion < latestVersion else {
            Logger.info("[Migration] Already at version \(currentVersion), no migrations needed")
            return
        }

        Logger.info("[Migration] Running migrations from v\(currentVersion) to v\(latestVersion)...")

        // Run migrations sequentially
        for migration in migrations where migration.version > currentVersion {
            await runMigration(migration)
        }

        // Update version
        updateVersion(to: latestVersion)
        Logger.info("[Migration] Migrations complete - now at v\(latestVersion)")
    }

    /// Check if migrations are needed (for showing loading indicator)
    func needsMigration() -> Bool {
        return getCurrentVersion() < latestVersion
    }

    // MARK: - Migration Definitions

    /// All migrations in order
    private var migrations: [Migration] {
        [
            Migration(
                version: 1,
                name: "performance_indexes",
                description: "Add missing indexes for Phase 4 performance improvements",
                type: .schema,
                execute: migration1_AddPerformanceIndexes
            ),
            Migration(
                version: 2,
                name: "missing_columns",
                description: "Add columns present in code but missing from initial schema DDL",
                type: .schema,
                execute: migration2_AddMissingColumns
            ),
            Migration(
                version: 3,
                name: "clip_comments_updated_at",
                description: "Add updated_at to local SQLite clip_comments table (BUG-01)",
                type: .schema,
                execute: migration3_AddClipCommentsUpdatedAt
            ),
            Migration(
                version: 4,
                name: "user_clip_history_genre_ids",
                description: "Add genre_ids to user_clip_history for mood analysis (BUG-04)",
                type: .schema,
                execute: migration4_AddGenreIdsToClipHistory
            ),
            Migration(
                version: 5,
                name: "personalized_discovery_order_columns",
                description: "Add carousel_order and batch_index to personalized_discovery for stable ordering",
                type: .schema,
                execute: migration5_AddCarouselOrderColumns
            )
        ]
    }

    // MARK: - Migration Implementation

    /// Migration 1: Add performance indexes (Phase 4)
    private func migration1_AddPerformanceIndexes() async throws {
        Logger.info("[Migration 1] Adding performance indexes...")

        // 1. Comments pagination index
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_clip_comments_pagination
            ON clip_comments(clip_id, created_at DESC) WHERE deleted_at IS NULL
        """)

        // 2. Gamification lookups
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_user_gamification_user
            ON user_gamification(user_id)
        """)

        // Check if xp_transactions table exists before creating index
        if tableExists("xp_transactions") {
            db.execute("""
                CREATE INDEX IF NOT EXISTS idx_xp_transactions_user_date
                ON xp_transactions(user_id, created_at DESC)
            """)
        }

        // 3. Sync outbox processing index
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_sync_outbox_pending
            ON sync_outbox(status, created_at ASC) WHERE status = 'pending'
        """)

        // 4. Clips random bucket for optimized random queries (Phase 4)
        if !db.columnExists("clips", column: "random_bucket") {
            db.execute("ALTER TABLE clips ADD COLUMN random_bucket INTEGER DEFAULT (ABS(RANDOM()) % 100)")

            // Populate random_bucket for existing rows
            db.execute("UPDATE clips SET random_bucket = ABS(RANDOM()) % 100 WHERE random_bucket IS NULL")
        }

        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_clips_bucket
            ON clips(is_active, random_bucket)
        """)

        // 5. Movie reactions index for faster lookups
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_movie_reactions_user_media
            ON movie_reactions(user_id, media_id, media_type)
        """)

        // 6. Lists pagination index
        db.execute("""
            CREATE INDEX IF NOT EXISTS idx_list_items_list_position
            ON list_items(list_id, position ASC) WHERE deleted_at IS NULL
        """)

        Logger.info("[Migration 1] Performance indexes added successfully")
    }

    /// Migration 2: Add columns that exist in INSERT statements but were missing from CREATE TABLE DDL
    private func migration2_AddMissingColumns() async throws {
        Logger.info("[Migration 2] Adding missing columns to fix silent INSERT failures...")

        // 1. personalized_discovery.media_data (CRITICAL: every carousel INSERT fails without this)
        if !db.columnExists("personalized_discovery", column: "media_data") {
            db.execute("ALTER TABLE personalized_discovery ADD COLUMN media_data TEXT")
            Logger.info("[Migration 2] Added media_data to personalized_discovery")
        }

        // 2. user_ai_token_usage.id + last_reset_at
        // The table uses user_id as PRIMARY KEY; id is used in REPLACE INTO statements as a regular column.
        if !db.columnExists("user_ai_token_usage", column: "id") {
            db.execute("ALTER TABLE user_ai_token_usage ADD COLUMN id TEXT")
            Logger.info("[Migration 2] Added id column to user_ai_token_usage")
        }
        if !db.columnExists("user_ai_token_usage", column: "last_reset_at") {
            db.execute("ALTER TABLE user_ai_token_usage ADD COLUMN last_reset_at TEXT")
            Logger.info("[Migration 2] Added last_reset_at to user_ai_token_usage")
        }

        // 3. user_daily_challenges.created_at
        if !db.columnExists("user_daily_challenges", column: "created_at") {
            db.execute("ALTER TABLE user_daily_challenges ADD COLUMN created_at TEXT DEFAULT (datetime('now'))")
            Logger.info("[Migration 2] Added created_at to user_daily_challenges")
        }

        // 4. user_clip_history: media_id, season_number, episode_number (queried by SmartNotificationService)
        if !db.columnExists("user_clip_history", column: "media_id") {
            db.execute("ALTER TABLE user_clip_history ADD COLUMN media_id INTEGER")
            Logger.info("[Migration 2] Added media_id to user_clip_history")
        }
        if !db.columnExists("user_clip_history", column: "season_number") {
            db.execute("ALTER TABLE user_clip_history ADD COLUMN season_number INTEGER")
            Logger.info("[Migration 2] Added season_number to user_clip_history")
        }
        if !db.columnExists("user_clip_history", column: "episode_number") {
            db.execute("ALTER TABLE user_clip_history ADD COLUMN episode_number INTEGER")
            Logger.info("[Migration 2] Added episode_number to user_clip_history")
        }

        Logger.info("[Migration 2] All missing columns added successfully")
    }

    /// Migration 3: Add updated_at to clip_comments (BUG-01 — column missing from local SQLite schema)
    private func migration3_AddClipCommentsUpdatedAt() async throws {
        if !db.columnExists("clip_comments", column: "updated_at") {
            db.execute("ALTER TABLE clip_comments ADD COLUMN updated_at TEXT DEFAULT (datetime('now'))")
            db.execute("UPDATE clip_comments SET updated_at = datetime('now') WHERE updated_at IS NULL")
            Logger.info("[Migration 3] Added updated_at to clip_comments")
        } else {
            Logger.info("[Migration 3] updated_at column already exists in clip_comments — skipping")
        }
    }

    /// Migration 5: Add carousel_order + batch_index to personalized_discovery for stable sort
    private func migration5_AddCarouselOrderColumns() async throws {
        if !db.columnExists("personalized_discovery", column: "carousel_order") {
            db.execute("ALTER TABLE personalized_discovery ADD COLUMN carousel_order INTEGER DEFAULT 999")
            Logger.info("[Migration 5] Added carousel_order to personalized_discovery")
        }
        if !db.columnExists("personalized_discovery", column: "batch_index") {
            db.execute("ALTER TABLE personalized_discovery ADD COLUMN batch_index INTEGER DEFAULT 0")
            Logger.info("[Migration 5] Added batch_index to personalized_discovery")
        }
    }

    /// Migration 4: Add genre_ids to user_clip_history (BUG-04 — required for mood analysis)
    private func migration4_AddGenreIdsToClipHistory() async throws {
        if !db.columnExists("user_clip_history", column: "genre_ids") {
            db.execute("ALTER TABLE user_clip_history ADD COLUMN genre_ids TEXT")
            Logger.info("[Migration 4] Added genre_ids to user_clip_history")
        } else {
            Logger.info("[Migration 4] genre_ids column already exists in user_clip_history — skipping")
        }
    }

    // MARK: - Version Management

    private func getCurrentVersion() -> Int {
        var versionString = "0"
        var statement: OpaquePointer?

        let sql = "SELECT value_text FROM app_metadata WHERE key_name = '\(versionKey)'"
        if sqlite3_prepare_v2(db.db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                if let versionPtr = sqlite3_column_text(statement, 0) {
                    versionString = String(cString: versionPtr)
                }
            }
            sqlite3_finalize(statement)
        }

        return Int(versionString) ?? 0
    }

    private func updateVersion(to version: Int) {
        db.execute("""
            INSERT OR REPLACE INTO app_metadata (key_name, value_text)
            VALUES ('\(versionKey)', '\(version)')
        """)
    }

    private func tableExists(_ tableName: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        if sqlite3_prepare_v2(db.db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, tableName, -1, nil)
            return sqlite3_step(statement) == SQLITE_ROW
        }
        return false
    }

    // MARK: - Migration Runner

    private func runMigration(_ migration: Migration) async {
        Logger.info("[Migration \(migration.version)] Starting: \(migration.name)")

        do {
            try await migration.execute()
            Logger.info("[Migration \(migration.version)] Completed: \(migration.name)")
        } catch {
            Logger.error("[Migration \(migration.version)] Failed: \(migration.name)", error: error)
            // Don't crash - log and continue
            // In production, you might want to report this to crash analytics
        }
    }
}

// MARK: - Migration Types

extension DatabaseMigrationManager {

    /// Type of migration
    enum MigrationType {
        case schema      // Database schema changes (tables, indexes)
        case data        // Data transformations
        case hybrid      // Both schema and data changes
    }

    /// Migration definition
    struct Migration {
        let version: Int
        let name: String
        let description: String
        let type: MigrationType
        let execute: () async throws -> Void
    }
}

// MARK: - Legacy Migration Bridge

extension DatabaseMigrationManager {

    /// Check if legacy migrations have been run
    /// Returns true if we need to mark legacy migrations as complete
    func checkLegacyMigrations() -> Bool {
        // Check if old migration systems have run
        let schemaVersion = getLegacyVersion(key: "migration_version")
        let personalizationVersion = getLegacyVersion(key: "personalization_migration_version")
        let dataPopulated = UserDefaults.standard.bool(forKey: "initialDataPopulated")

        // If any legacy migration has run, we're not a fresh install
        return schemaVersion > 0 || personalizationVersion > 0 || dataPopulated
    }

    private func getLegacyVersion(key: String) -> Int {
        var versionString = "0"
        var statement: OpaquePointer?

        let sql = "SELECT value_text FROM app_metadata WHERE key_name = '\(key)'"
        if sqlite3_prepare_v2(db.db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                if let versionPtr = sqlite3_column_text(statement, 0) {
                    versionString = String(cString: versionPtr)
                }
            }
            sqlite3_finalize(statement)
        }

        return Int(versionString) ?? 0
    }
}
