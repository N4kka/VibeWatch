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
    private let latestVersion = 1

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
