import Foundation
import SQLite3

// MARK: - Phase 5: SQL Injection Prevention

/// Whitelist of valid table names to prevent SQL injection
/// Only tables in this enum can be used in dynamic SQL queries
enum SQLiteTable: String, CaseIterable {
    // Core content tables
    case clips
    case discoveryCache = "discovery_cache"
    case mediaDetailsCache = "media_details_cache"
    case detailCache = "detail_cache"
    case trailersCache = "trailers_cache"

    // User tables
    case profiles
    case lists
    case listItems = "list_items"

    // Public lists (Fase 1)
    case listFollows = "list_follows"
    case userBlocks = "user_blocks"
    case listReports = "list_reports"
    case publicListsCache = "public_lists_cache"

    // User activity tables
    case userClipHistory = "user_clip_history"
    case userClipSignals = "user_clip_signals"
    case userPreferences = "user_preferences"
    case userDailyQuota = "user_daily_quota"
    case userAiTokenUsage = "user_ai_token_usage"

    // Sync tables
    case syncOutbox = "sync_outbox"
    case syncLog = "sync_log"

    // Device/App tables
    case deviceInfo = "device_info"
    case appMetadata = "app_metadata"

    // Reactions & Comments
    case movieReactions = "movie_reactions"
    case movieReactionCounts = "movie_reaction_counts"
    case clipReactions = "clip_reactions"
    case clipComments = "clip_comments"
    case clipCommentLikes = "clip_comment_likes"

    // Gamification
    case userGamification = "user_gamification"
    case userBadges = "user_badges"
    case userDailyChallenges = "user_daily_challenges"
    case xpTransactions = "xp_transactions"

    // Personalization (SQLiteMigrations)
    case userSearchHistory = "user_search_history"
    case userDiscoveryInteractions = "user_discovery_interactions"
    case unifiedUserPreferences = "unified_user_preferences"
    case personalizedDiscovery = "personalized_discovery"
    case aiConversationHistory = "ai_conversation_history"
    case globalDiscoveryFilters = "global_discovery_filters"

    // Cerebras/AI tables
    case cerebrasJobQueue = "cerebras_job_queue"
    case mediaEmbeddings = "media_embeddings"
    case userBehaviorInsights = "user_behavior_insights"
    case cerebrasJobMetrics = "cerebras_job_metrics"
    case userTimePatterns = "user_time_patterns"

    // Notifications
    case notificationHistory = "notification_history"
    case userNotificationPreferences = "user_notification_preferences"
    case notificationSubscriptions = "notification_subscriptions"

    // Watch providers (created by migration 5, never whitelisted: every insert/update from
    // LocalWatchProvidersRepository threw invalidTableName and died under a `try?`).
    case watchProviders = "watch_providers"

    // Tracking episodi (SPEC v3 §4). `user_ratings`, `user_favorites` e `user_follows` sono
    // nell'elenco di §4 ma NON qui: non esistono ancora lato server (arrivano coi blocchi 8 e 9),
    // e metterle ora significherebbe un PGRST205 a ogni sync.
    case watchEvents = "watch_events"
    case tvShowState = "tv_show_state"

    /// All valid table names as a Set for O(1) lookup
    static let validTableNames: Set<String> = Set(SQLiteTable.allCases.map(\.rawValue))

    /// Check if a table name is valid (safe to use in SQL)
    static func isValid(_ tableName: String) -> Bool {
        validTableNames.contains(tableName)
    }
}

/// Local SQLite database service for offline-first architecture
/// All app reads/writes go through this service
final class SQLiteService: ObservableObject {
    static let shared = SQLiteService()

    @Published var isConnected = false
    @Published var lastError: String?

    var db: OpaquePointer?
    private var readerDb: OpaquePointer?
    private let dbPath: String
    private let writerQueue = DispatchQueue(label: "com.vibewatch.sqlite.writer", qos: .userInitiated)
    let readerQueue = DispatchQueue(
        label: "com.vibewatch.sqlite.reader",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// True when personalized_discovery table has at least one row.
    /// Set synchronously at init() before any concurrent access begins.
    private(set) var hasPersonalizedDiscoveryCache: Bool = false

    /// Bumped whenever the CREATE TABLE / CREATE INDEX scripts below change. `createTables()` is
    /// on the launch path and runs on the main thread, so it re-runs only when this differs from
    /// what is stored in app_metadata. Raised to 1.1.0 because until now every declared index was
    /// being discarded (see executeScript), so existing installs need one more creation pass to
    /// finally get them.
    private static let schemaVersion = "1.1.0"

    // Wrappers to allow capturing dynamic SQLite values in @Sendable contexts.
    private struct SQLSendableValue: @unchecked Sendable { let raw: Any }
    private struct SQLSendableRecord: @unchecked Sendable { var raw: [String: Any] }

    /// Set to false only by the test that asserts the throw itself. See `validateTableName`.
    static var trapsOnUnknownTable = true

    /// Validate table name to prevent SQL injection (Phase 5 Security).
    ///
    /// P1: an unknown table is almost never an injection attempt — it is a table that exists in
    /// SQLite but was never added to the whitelist, and the resulting throw kept dying under a
    /// `try?` at the call site (`watch_providers` did exactly that: created by migration 5, absent
    /// from the enum, every write lost with no log anyone read). Debug builds now trap, so a
    /// missing whitelist entry surfaces on the first write during development instead of in
    /// production as missing data.
    private func validateTableName(_ table: String) throws {
        guard SQLiteTable.isValid(table) else {
            Logger.error("[SQLite] Rejected statement on non-whitelisted table '\(table)'. "
                         + "If the table is legitimate, add it to SQLiteTable.")
            if Self.trapsOnUnknownTable {
                assertionFailure("[SQLite] non-whitelisted table '\(table)' — add it to SQLiteTable")
            }
            throw SQLiteError.invalidTableName(table)
        }
    }

    /// Phase 5 (1.10): a column name is a plain SQL identifier (letters, digits, underscore,
    /// not starting with a digit). Column names from caller-provided dictionaries are
    /// interpolated into SQL (the VALUES go through `?`), so they must be validated to keep
    /// the `columns`/`setClause` fragments injection-proof. Pure function for testability.
    nonisolated static func isValidColumnIdentifier(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// Validate caller-provided column identifiers before interpolating them into SQL.
    private func validateColumnNames(_ names: some Collection<String>) throws {
        for name in names where !Self.isValidColumnIdentifier(name) {
            Logger.error("[SQLite] SQL injection attempt blocked: invalid column '\(name)'")
            throw SQLiteError.invalidColumnName(name)
        }
    }
    
    /// Designated initializer. Tests can pass a temporary/isolated database file path
    /// to exercise real persistence without touching the production store.
    init(dbPath: String) {
        self.dbPath = dbPath

        Logger.info("[SQLite] Database path: \(dbPath)")

        openDatabase()
        createTables()
        checkInitialCacheState()
    }

    private convenience init() {
        // Store in app's Documents directory
        let fileManager = FileManager.default
        let urls = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        self.init(dbPath: urls[0].appendingPathComponent("vibewatch_local.sqlite").path)
    }

    deinit {
        if let readerDb = readerDb {
            sqlite3_close(readerDb)
        }
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    /// Wipe the local database file and recreate schema
    func resetDatabase() {
        closeDatabase()
        
        do {
            try FileManager.default.removeItem(atPath: dbPath)
            Logger.info("[SQLite] Database file deleted at \(dbPath)")
        } catch {
            Logger.error("[SQLite] Failed to delete database: \(error.localizedDescription)")
        }
        
        db = nil
        readerDb = nil
        openDatabase()
        createTables()
        checkInitialCacheState()
    }

    // MARK: - Connection Management
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            isConnected = true
            lastError = nil

            // Enable foreign keys
            execute("PRAGMA foreign_keys = ON")

            // Enable WAL mode for better concurrency
            execute("PRAGMA journal_mode = WAL")

            // Open read-only connection after WAL is confirmed active
            openReaderConnection()

            Logger.info("[SQLite] Database opened successfully")
        } else {
            isConnected = false
            lastError = String(cString: sqlite3_errmsg(db))
            Logger.error("[SQLite] Failed to open database: \(lastError ?? "unknown")")
        }
    }

    private func openReaderConnection() {
        // SQLITE_OPEN_FULLMUTEX ensures thread safety when readerQueue dispatches
        // multiple concurrent closures that share this single read-only connection.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbPath, &readerDb, Int32(flags), nil) != SQLITE_OK {
            Logger.error("[SQLite] Failed to open reader connection: \(String(cString: sqlite3_errmsg(readerDb)))")
        }
    }
    
    private func closeDatabase() {
        if let readerDb = readerDb, sqlite3_close(readerDb) == SQLITE_OK {
            Logger.info("[SQLite] Reader connection closed")
        }
        if sqlite3_close(db) == SQLITE_OK {
            Logger.info("[SQLite] Database closed")
        }
    }

    /// Check whether personalized_discovery has any rows.
    /// Uses raw sqlite3_* calls directly on db — NOT execute() — to avoid
    /// dbQueue re-entrancy. Safe to call from init() after createTables().
    private func checkInitialCacheState() {
        var stmt: OpaquePointer?
        // Only "does a row exist" is needed. COUNT(*) is an aggregate, so `LIMIT 1` bounded
        // nothing and the whole table was scanned — on the main thread, at every launch.
        let sql = "SELECT 1 FROM personalized_discovery LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        hasPersonalizedDiscoveryCache = sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Returns true when personalized_discovery table has at least one row.
    /// Reflects the value set synchronously at init().
    func hasCachedPersonalizedContent() -> Bool {
        hasPersonalizedDiscoveryCache
    }

    /// Re-runs the cache state check and updates hasPersonalizedDiscoveryCache.
    /// Call this after modifying personalized_discovery to keep the property current.
    func refreshCacheState() {
        checkInitialCacheState()
    }

    /// Test database connection
    func testConnection() async -> Bool {
        do {
            let result: [[String: Any]] = try await queryRaw("SELECT 1 as test")
            return result.first?["test"] as? Int == 1
        } catch {
            Logger.error("[SQLite] Connection test failed", error: error)
            return false
        }
    }
    
    /// Debug: Print all reaction counts
    func debugPrintReactionCounts() async {
        do {
            let counts: [[String: Any]] = try await queryRaw("""
                SELECT media_id, media_type, like_count, dislike_count, updated_at
                FROM movie_reaction_counts
                ORDER BY updated_at DESC
            """)
            
            Logger.debug("📊 [SQLite] Reaction Counts:")
            Logger.debug("============================================================")
            for row in counts {
                let mediaId = row["media_id"] as? Int ?? 0
                let mediaType = row["media_type"] as? String ?? ""
                let likes = row["like_count"] as? Int ?? 0
                let dislikes = row["dislike_count"] as? Int ?? 0
                let updated = row["updated_at"] as? String ?? ""
                Logger.debug("  \(mediaType) #\(mediaId): 👍 \(likes) | 👎 \(dislikes) (updated: \(updated))")
            }
            Logger.debug("============================================================")
            Logger.debug("Total: \(counts.count) movies/shows with reactions")
        } catch {
            Logger.error("[SQLite] Failed to fetch reaction counts", error: error)
        }
    }
    
    /// Debug: Print all tables
    func debugPrintAllTables() async {
        do {
            let tables: [[String: Any]] = try await queryRaw("""
                SELECT name FROM sqlite_master 
                WHERE type='table' 
                ORDER BY name
            """)
            
            Logger.debug("📋 [SQLite] All Tables:")
            for table in tables {
                if let name = table["name"] as? String {
                    Logger.debug("  - \(name)")
                }
            }
        } catch {
            Logger.error("[SQLite] Failed to list tables", error: error)
        }
    }
    
    // MARK: - Schema Creation
    
    private func createTables() {
        // app_metadata has to exist before its own version marker can be read.
        executeScript(createAppMetadataTable())

        // The scripts below are idempotent but not free, and this runs on the main thread before
        // the first frame on every single launch. Skip the whole pass once the stored schema
        // version matches; migrations below stay outside the gate since they carry their own.
        if readSchemaVersion() == Self.schemaVersion {
            runMigrations()
            runPersonalizationMigrations()
            return
        }

        // Read schema from file or create inline
        let tables = [
            createClipsTable(),
            createDiscoveryCacheTable(),
            createMediaDetailsTable(),
            createDetailCacheTable(),
            createTrailersTable(),
            createProfilesTable(),
            createListsTable(),
            createListItemsTable(),
            createListFollowsTable(),
            createUserBlocksTable(),
            createListReportsTable(),
            createPublicListsCacheTable(),
            createUserClipHistoryTable(),
            createUserClipSignalsTable(),
            createUserPreferencesTable(),
            createUserDailyQuotaTable(),
            createUserAITokenUsageTable(),
            createSyncOutboxTable(),
            createSyncLogTable(),
            createDeviceInfoTable(),
            createAppMetadataTable(),
            // Reactions & Comments tables
            createMovieReactionsTable(),
            createMovieReactionCountsTable(),
            createClipReactionsTable(),
            createClipCommentsTable(),
            createClipCommentLikesTable(),
            // Gamification tables
            createUserGamificationTable(),
            createUserBadgesTable(),
            createUserDailyChallengesTable(),
            createXPTransactionsTable()
        ]
        
        // executeScript, not execute: each of these strings is a CREATE TABLE followed by its
        // CREATE INDEX statements, and prepare_v2 would compile only the first of them.
        for table in tables {
            executeScript(table)
        }

        // Initialize metadata
        execute("""
            INSERT OR IGNORE INTO app_metadata (key_name, value_text) VALUES
            ('app_install_date', datetime('now')),
            ('last_full_sync', NULL)
        """)

        writeSchemaVersion(Self.schemaVersion)

        Logger.info("[SQLite] Schema created (version \(Self.schemaVersion))")

        // Run migrations
        runMigrations()

        // Run personalization migrations (Phase 1)
        runPersonalizationMigrations()
    }

    /// Reads the stored schema marker directly, without going through the async query path:
    /// this is called from init() on the launch path.
    private func readSchemaVersion() -> String? {
        var statement: OpaquePointer?
        let sql = "SELECT value_text FROM app_metadata WHERE key_name = 'db_schema_version'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func writeSchemaVersion(_ version: String) {
        execute(
            """
            INSERT INTO app_metadata (key_name, value_text) VALUES ('db_schema_version', ?)
            ON CONFLICT(key_name) DO UPDATE SET value_text = excluded.value_text
            """,
            parameters: [version]
        )
    }
    
    private func runMigrations() {
        // Check if migrations have already been run using synchronous execute
        var migrationVersionString = "0"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, "SELECT value_text FROM app_metadata WHERE key_name = 'migration_version'", -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                if let versionPtr = sqlite3_column_text(statement, 0) {
                    migrationVersionString = String(cString: versionPtr)
                }
            }
            sqlite3_finalize(statement)
        }
        
        let currentVersion = Int(migrationVersionString) ?? 0
        let latestVersion = 7
        
        // Only run migrations if not already at latest version
        if currentVersion >= latestVersion {
            Logger.info("[SQLite] Migrations already applied (version \(migrationVersionString))")
            return
        }
        
        Logger.info("[SQLite] Running migrations from version \(currentVersion) to version \(latestVersion)...")
        
        // Temporarily disable foreign keys for migration
        execute("PRAGMA foreign_keys = OFF")
        
        if currentVersion < 1 {
            // Migration 1: Fix clip_comments and clip_reactions foreign key constraints
            Logger.info("[SQLite] Migration 1: recreate clip_comments and clip_reactions tables")
            
            execute("DROP TABLE IF EXISTS clip_comments")
            execute("DROP INDEX IF EXISTS idx_clip_comments_clip")
            execute("DROP INDEX IF EXISTS idx_clip_comments_parent")
            execute("DROP INDEX IF EXISTS idx_clip_comments_user")
            execute(createClipCommentsTable())
            
            execute("DROP TABLE IF EXISTS clip_reactions")
            execute("DROP INDEX IF EXISTS idx_clip_reactions_user")
            execute("DROP INDEX IF EXISTS idx_clip_reactions_clip")
            execute(createClipReactionsTable())
        }
        
        if currentVersion < 2 {
            // Migration 2: add updated_at + user FK to clip_reactions and user FK to clip_comments without dropping data
            Logger.info("[SQLite] Migration 2: rehydrate clip_reactions with updated_at + user FK")
            execute("""
                CREATE TABLE IF NOT EXISTS clip_reactions_new (
                  id TEXT PRIMARY KEY,
                  user_id TEXT NOT NULL,
                  clip_id TEXT NOT NULL,
                  reaction_type TEXT NOT NULL DEFAULT 'like',
                  created_at TEXT DEFAULT (datetime('now')),
                  updated_at TEXT DEFAULT (datetime('now')),
                  UNIQUE(user_id, clip_id, reaction_type),
                  FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
                );
            """)
            execute("""
                INSERT OR IGNORE INTO clip_reactions_new (id, user_id, clip_id, reaction_type, created_at)
                SELECT id, user_id, clip_id, reaction_type, created_at FROM clip_reactions
            """)
            execute("DROP TABLE IF EXISTS clip_reactions")
            execute("ALTER TABLE clip_reactions_new RENAME TO clip_reactions")
            execute("CREATE INDEX IF NOT EXISTS idx_clip_reactions_user ON clip_reactions(user_id)")
            execute("CREATE INDEX IF NOT EXISTS idx_clip_reactions_clip ON clip_reactions(clip_id)")
            
            Logger.info("[SQLite] Migration 2: rehydrate clip_comments with user FK")
            execute("""
                CREATE TABLE IF NOT EXISTS clip_comments_new (
                  id TEXT PRIMARY KEY,
                  clip_id TEXT NOT NULL,
                  user_id TEXT NOT NULL,
                  parent_comment_id TEXT,
                  content TEXT NOT NULL,
                  like_count INTEGER DEFAULT 0,
                  reply_count INTEGER DEFAULT 0,
                  created_at TEXT DEFAULT (datetime('now')),
                  updated_at TEXT DEFAULT (datetime('now')),
                  deleted_at TEXT,
                  FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE,
                  FOREIGN KEY (parent_comment_id) REFERENCES clip_comments(id) ON DELETE CASCADE
                );
            """)
            execute("""
                INSERT OR IGNORE INTO clip_comments_new (
                  id, clip_id, user_id, parent_comment_id, content,
                  like_count, reply_count, created_at, updated_at, deleted_at
                )
                SELECT id, clip_id, user_id, parent_comment_id, content,
                       like_count, reply_count, created_at, updated_at, deleted_at
                FROM clip_comments
            """)
            execute("DROP TABLE IF EXISTS clip_comments")
            execute("ALTER TABLE clip_comments_new RENAME TO clip_comments")
            execute("CREATE INDEX IF NOT EXISTS idx_clip_comments_clip ON clip_comments(clip_id, deleted_at)")
            execute("CREATE INDEX IF NOT EXISTS idx_clip_comments_parent ON clip_comments(parent_comment_id)")
            execute("CREATE INDEX IF NOT EXISTS idx_clip_comments_user ON clip_comments(user_id)")
        }
        
        if currentVersion < 3 {
            Logger.info("[SQLite] Migration 3: add synced_at columns for offline sync tracking")
            if !columnExists("clip_reactions", column: "synced_at") {
                execute("ALTER TABLE clip_reactions ADD COLUMN synced_at TEXT")
            }
            if !columnExists("clip_comments", column: "synced_at") {
                execute("ALTER TABLE clip_comments ADD COLUMN synced_at TEXT")
            }
            if !columnExists("clip_comment_likes", column: "synced_at") {
                execute("ALTER TABLE clip_comment_likes ADD COLUMN synced_at TEXT")
            }
        }

        if currentVersion < 4 {
            Logger.info("[SQLite] Migration 4: add usage_day to user_ai_token_usage for daily resets")
            if !columnExists("user_ai_token_usage", column: "usage_day") {
                execute("ALTER TABLE user_ai_token_usage ADD COLUMN usage_day TEXT")
            }
        }

        if currentVersion < 5 {
            Logger.info("[SQLite] Migration 5: add watch_providers table and vote_count to detail_cache")
            execute("""
                CREATE TABLE IF NOT EXISTS watch_providers (
                  id TEXT PRIMARY KEY,
                  media_id INTEGER NOT NULL,
                  media_type TEXT NOT NULL,
                  region TEXT NOT NULL,
                  providers_json TEXT NOT NULL,
                  refreshed_at TEXT NOT NULL,
                  expires_at TEXT NOT NULL,
                  UNIQUE(media_id, media_type, region)
                )
            """)
            execute("CREATE INDEX IF NOT EXISTS idx_watch_providers_lookup ON watch_providers(media_id, media_type, region)")
            if !columnExists("detail_cache", column: "vote_count") {
                execute("ALTER TABLE detail_cache ADD COLUMN vote_count INTEGER DEFAULT 0")
            }
        }

        if currentVersion < 6 {
            // Migration 6: collapse duplicate CORE lists (watchlist/seen/liked/disliked).
            //
            // Bug "gli item spariscono al riavvio": una nuova quaterna di liste core con UUID
            // nuovi veniva sintetizzata quasi a ogni avvio (ensureCoreLists + ensureListsInDatabase
            // + syncListsForAuthenticatedUser). loadListsFromSQLite ordina created_at DESC e la UI
            // prende `.first` per tipo → la duplicata PIÙ RECENTE, che è VUOTA. Gli item reali
            // restavano incagliati su una riga più vecchia → apparivano persi.
            //
            // Collapse NON distruttivo: per ogni (user_id, type) core si elegge una canonica
            // (quella con più item, tie-break created_at più vecchio), vi si ri-puntano tutti gli
            // item delle duplicate (soft-deletando i soli item realmente duplicati per evitare
            // conflitti su UNIQUE(list_id, media_id, media_type)) e si soft-deletano le duplicate.
            // Infine un indice univoco parziale impedisce strutturalmente nuove duplicate attive.
            Logger.info("[SQLite] Migration 6: collapse duplicate core lists + guard index")

            execute("DROP TABLE IF EXISTS _canon")
            execute("""
                CREATE TEMP TABLE _canon AS
                SELECT user_id, type, id AS canon_id FROM (
                  SELECT l.user_id, l.type, l.id,
                    ROW_NUMBER() OVER (
                      PARTITION BY l.user_id, l.type
                      ORDER BY (SELECT count(*) FROM list_items i WHERE i.list_id = l.id AND i.deleted_at IS NULL) DESC,
                               l.created_at ASC,
                               l.id ASC
                    ) AS rn
                  FROM lists l
                  WHERE l.type IN ('watchlist','seen','liked','disliked') AND l.deleted_at IS NULL
                ) WHERE rn = 1
            """)

            execute("DROP TABLE IF EXISTS _listmap")
            execute("""
                CREATE TEMP TABLE _listmap AS
                SELECT l.id AS old_id, c.canon_id AS new_id
                FROM lists l
                JOIN _canon c ON l.user_id = c.user_id AND l.type = c.type
                WHERE l.type IN ('watchlist','seen','liked','disliked')
                  AND l.deleted_at IS NULL
                  AND l.id <> c.canon_id
            """)

            // Soft-delete duplicate items keyed by EFFECTIVE target list (canon if mover, else self)
            // + media, keeping the earliest added_at. Prevents UNIQUE collisions when re-pointing.
            execute("""
                UPDATE list_items
                SET deleted_at = datetime('now'), updated_at = datetime('now')
                WHERE id IN (
                  SELECT id FROM (
                    SELECT li.id,
                      ROW_NUMBER() OVER (
                        PARTITION BY COALESCE((SELECT m.new_id FROM _listmap m WHERE m.old_id = li.list_id), li.list_id),
                                     li.media_id, li.media_type
                        ORDER BY li.added_at ASC, li.id ASC
                      ) AS rn
                    FROM list_items li
                    WHERE li.deleted_at IS NULL
                      AND COALESCE((SELECT m.new_id FROM _listmap m WHERE m.old_id = li.list_id), li.list_id)
                          IN (SELECT canon_id FROM _canon)
                  ) WHERE rn > 1
                )
            """)

            // Re-point the remaining (now conflict-free) items to their canonical list.
            execute("""
                UPDATE list_items
                SET list_id = (SELECT m.new_id FROM _listmap m WHERE m.old_id = list_items.list_id),
                    updated_at = datetime('now')
                WHERE deleted_at IS NULL
                  AND list_id IN (SELECT old_id FROM _listmap)
            """)

            // Soft-delete the now-redundant non-canonical core lists.
            execute("""
                UPDATE lists
                SET deleted_at = datetime('now'), updated_at = datetime('now')
                WHERE id IN (SELECT old_id FROM _listmap)
            """)

            execute("DROP TABLE IF EXISTS _canon")
            execute("DROP TABLE IF EXISTS _listmap")

            // Structural guard: at most ONE active core list per (user_id, type) going forward.
            // With this in place a stray INSERT OR IGNORE for a new-UUID core list is a no-op,
            // and ListManager.reconcileCoreListIdentities() keeps the in-memory id canonical.
            execute("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_lists_one_core_per_user_type
                ON lists(user_id, type)
                WHERE type IN ('watchlist','seen','liked','disliked') AND deleted_at IS NULL
            """)

            // Purge unrecoverable list_items outbox ops stuck on the legacy `created_at` column
            // mismatch (Postgres 42703). The items themselves live locally; these ops only retry-fail.
            execute("DELETE FROM sync_outbox WHERE table_name = 'list_items' AND last_error LIKE '%42703%'")
        }

        if currentVersion < 7 {
            // Migration 7: Liste Pubbliche (Fase 1).
            // - `is_public` su lists (mirror locale dello stato server; solo custom diventano pubbliche)
            // - tabelle locali per outbox/offline: list_follows, user_blocks, list_reports
            // - cache metadati per la tab "Followed" offline
            Logger.info("[SQLite] Migration 7: public lists (is_public + follows/blocks/reports + cache)")
            if !columnExists("lists", column: "is_public") {
                execute("ALTER TABLE lists ADD COLUMN is_public INTEGER NOT NULL DEFAULT 0")
            }
            execute(createListFollowsTable())
            execute(createUserBlocksTable())
            execute(createListReportsTable())
            execute(createPublicListsCacheTable())
        }

        // Re-enable foreign keys
        execute("PRAGMA foreign_keys = ON")

        // STAB-003: only record the new version if the schema it promises is actually there.
        // Every execute() above returns a Bool that the migration ignored, so a failed ALTER/CREATE
        // used to be invisible and the version was bumped anyway — leaving a store permanently
        // half-migrated (next launch sees version >= latest and skips, so it never heals). Instead
        // of a transactional rewrite of this launch-critical path (high risk, no tests), we verify
        // the distinctive artifact of each migration and refuse to claim the version until they're
        // all present. A partial migration then simply retries on the next launch.
        let missing = missingMigrationArtifacts()
        guard missing.isEmpty else {
            Logger.error("[SQLite] Migration incomplete — NOT recording version \(latestVersion). "
                         + "Missing: \(missing.joined(separator: ", ")). Will retry next launch.")
            return
        }

        execute("INSERT OR REPLACE INTO app_metadata (key_name, value_text) VALUES ('migration_version', '\(latestVersion)')")
        Logger.info("[SQLite] Migrations complete - now at version \(latestVersion)")
    }

    /// Returns the labels of any expected end-state artifacts (columns, tables, indexes) that the
    /// migrations 1–7 should have produced but didn't. Empty means the schema matches what the
    /// latest version promises. Used to gate the version bump (STAB-003).
    private func missingMigrationArtifacts() -> [String] {
        var missing: [String] = []
        func requireColumn(_ table: String, _ column: String) {
            if !columnExists(table, column: column) { missing.append("\(table).\(column)") }
        }
        func requireObject(_ name: String) {
            if !objectExists(name) { missing.append(name) }
        }
        requireColumn("clip_reactions", "updated_at")   // migration 2
        requireColumn("clip_reactions", "synced_at")    // migration 3
        requireColumn("user_ai_token_usage", "usage_day") // migration 4
        requireObject("watch_providers")                // migration 5
        requireColumn("detail_cache", "vote_count")     // migration 5
        requireObject("idx_lists_one_core_per_user_type") // migration 6
        requireColumn("lists", "is_public")             // migration 7
        requireObject("list_follows")                   // migration 7
        requireObject("public_lists_cache")             // migration 7
        return missing
    }

    /// True if a table or index with this name exists. Sync, C-API, mirrors columnExists.
    func objectExists(_ name: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type IN ('table','index') AND name = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(statement) == SQLITE_ROW
    }
    
    func columnExists(_ table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        let pragmaSQL = "PRAGMA table_info(\(table))"
        if sqlite3_prepare_v2(db, pragmaSQL, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(statement, 1) {
                    let name = String(cString: namePtr)
                    if name == column {
                        return true
                    }
                }
            }
        }
        return false
    }
    
    // MARK: - SQL Execution
    
    /// Execute a SQL statement without returning results
    @discardableResult
    func execute(_ sql: String, parameters: [Any] = []) -> Bool {
        var success = false

        writerQueue.sync { [weak self] in
            guard let self = self else { return }

            var statement: OpaquePointer?

            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                let error = String(cString: sqlite3_errmsg(self.db))
                Logger.error("[SQLite] Prepare failed: \(error). SQL: \(sql)")
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = error
                }
                return
            }

            defer { sqlite3_finalize(statement) }

            // Bind parameters
            for (index, param) in parameters.enumerated() {
                Self.bindValue(param, to: statement, at: Int32(index + 1))
            }

            if sqlite3_step(statement) != SQLITE_DONE {
                let error = String(cString: sqlite3_errmsg(self.db))
                Logger.error("[SQLite] Execute failed: \(error). SQL: \(sql)")
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = error
                }
                return
            }

            success = true
        }

        return success
    }

    /// Execute a multi-statement SQL script.
    ///
    /// `execute(_:)` above compiles with `sqlite3_prepare_v2`, which only ever compiles the FIRST
    /// statement in the string — the rest is reachable solely through the `pzTail` out-parameter,
    /// which is passed as nil. Every `createXTable()` returns a CREATE TABLE followed by its
    /// CREATE INDEX statements in one string, so all 73 declared indexes were being silently
    /// dropped: production databases only ever had the implicit PRIMARY KEY autoindexes.
    ///
    /// `sqlite3_exec` runs the whole script. Splitting on ";" would have been the obvious fix and
    /// is wrong — it breaks on any semicolon inside a string literal or trigger body.
    @discardableResult
    func executeScript(_ sql: String) -> Bool {
        var success = false

        writerQueue.sync { [weak self] in
            guard let self = self else { return }

            var errorPointer: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(self.db, sql, nil, nil, &errorPointer) == SQLITE_OK {
                success = true
            } else {
                let error = errorPointer.map { String(cString: $0) } ?? "unknown error"
                Logger.error("[SQLite] Script failed: \(error). SQL: \(sql)")
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = error
                }
            }
            if let errorPointer { sqlite3_free(errorPointer) }
        }

        return success
    }

    /// Execute a write statement (INSERT/UPDATE/DELETE/REPLACE) on the writer connection.
    /// Unlike `queryRaw`, whose connection is opened `SQLITE_OPEN_READONLY`, this can actually
    /// write — and it throws on failure instead of returning an empty result set.
    func executeWrite(_ sql: String, parameters: [Any] = []) async throws {
        let safeParameters = parameters.map(SQLSendableValue.init(raw:))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerQueue.async { [weak self, safeParameters] in
                guard let self = self else {
                    continuation.resume(throwing: SQLiteError.notConnected)
                    return
                }

                var statement: OpaquePointer?

                guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    let error = String(cString: sqlite3_errmsg(self.db))
                    Logger.error("[SQLite] Write prepare failed: \(error). SQL: \(sql)")
                    continuation.resume(throwing: SQLiteError.queryFailed(error))
                    return
                }

                defer { sqlite3_finalize(statement) }

                for (index, param) in safeParameters.enumerated() {
                    Self.bindValue(param.raw, to: statement, at: Int32(index + 1))
                }

                // RETURNING clauses step to SQLITE_ROW; plain writes step to SQLITE_DONE.
                let rc = sqlite3_step(statement)
                guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                    let error = String(cString: sqlite3_errmsg(self.db))
                    Logger.error("[SQLite] Write failed (rc \(rc)): \(error). SQL: \(sql)")
                    continuation.resume(throwing: SQLiteError.queryFailed(error))
                    return
                }

                continuation.resume(returning: ())
            }
        }
    }

    /// Query and return rows as dictionaries
    func queryRaw(_ sql: String, parameters: [Any] = []) async throws -> [[String: Any]] {
        let safeParameters = parameters.map(SQLSendableValue.init(raw:))
        
        return try await withCheckedThrowingContinuation { continuation in
            readerQueue.async { [weak self, safeParameters] in
                guard let self = self else {
                    continuation.resume(throwing: SQLiteError.notConnected)
                    return
                }

                var statement: OpaquePointer?

                guard sqlite3_prepare_v2(self.readerDb, sql, -1, &statement, nil) == SQLITE_OK else {
                    let error = String(cString: sqlite3_errmsg(self.readerDb))
                    continuation.resume(throwing: SQLiteError.queryFailed(error))
                    return
                }

                defer { sqlite3_finalize(statement) }

                // This connection is SQLITE_OPEN_READONLY: a write statement prepares fine but
                // steps to SQLITE_READONLY, which the row loop below would swallow as an empty
                // result — a silent no-op. Reroute it to the writer connection instead of losing it.
                if sqlite3_stmt_readonly(statement) == 0 {
                    sqlite3_finalize(statement)
                    statement = nil  // defer above finalizes nil, which is a no-op
                    Logger.error("[SQLite] Write statement passed to queryRaw; rerouted to the writer connection. Use executeWrite instead. SQL: \(sql)")
                    Task { [weak self, safeParameters] in
                        guard let self = self else {
                            continuation.resume(throwing: SQLiteError.notConnected)
                            return
                        }
                        do {
                            try await self.executeWrite(sql, parameters: safeParameters.map(\.raw))
                            continuation.resume(returning: [])
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    return
                }

                // Bind parameters
                for (index, param) in safeParameters.enumerated() {
                    Self.bindValue(param.raw, to: statement, at: Int32(index + 1))
                }

                var results: [SQLSendableRecord] = []

                while sqlite3_step(statement) == SQLITE_ROW {
                    var row: [String: Any] = [:]
                    let columnCount = sqlite3_column_count(statement)

                    for i in 0..<columnCount {
                        let columnName = String(cString: sqlite3_column_name(statement, i))
                        let value = self.getValue(from: statement, at: i)
                        row[columnName] = value
                    }

                    results.append(SQLSendableRecord(raw: row))
                }

                continuation.resume(returning: results.map { $0.raw })
            }
        }
    }

    // MARK: - Generic Upsert Helpers

    /// Simple in-memory cache of table columns to avoid repeated PRAGMA calls.
    private var tableColumnsCache: [String: [String]] = [:]

    /// Fetch column names for a table.
    private func columns(for table: String) async throws -> [String] {
        try validateTableName(table)  // Phase 5: SQL injection prevention
        if let cached = tableColumnsCache[table] { return cached }
        let pragmaRows = try await queryRaw("PRAGMA table_info(\(table))")
        let names = pragmaRows.compactMap { $0["name"] as? String }
        tableColumnsCache[table] = names
        return names
    }

    /// Cache of conflict targets per table, alongside `tableColumnsCache`.
    private var tableConflictTargetsCache: [String: [[String]]] = [:]

    /// The conflict targets usable in an `ON CONFLICT (…) DO UPDATE` clause for a table:
    /// its PRIMARY KEY plus every non-partial UNIQUE index.
    ///
    /// Partial unique indexes are deliberately excluded. SQLite requires their WHERE clause to be
    /// repeated verbatim in the conflict target, and reconstructing it from `sqlite_master` is more
    /// fragile than it is worth: a collision on one of them raises instead, which is loud but safe.
    private func conflictTargets(for table: String) async throws -> [[String]] {
        try validateTableName(table)
        if let cached = tableConflictTargetsCache[table] { return cached }

        var targets: [[String]] = []

        // PRIMARY KEY, in declaration order — `pk` is 1-based and identifies the position of the
        // column within a composite key, so it doubles as the sort key.
        let primaryKey = try await queryRaw("PRAGMA table_info(\(table))")
            .compactMap { row -> (Int, String)? in
                guard let position = row["pk"] as? Int, position > 0,
                      let name = row["name"] as? String else { return nil }
                return (position, name)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        if !primaryKey.isEmpty { targets.append(primaryKey) }

        for index in try await queryRaw("PRAGMA index_list(\(table))") {
            guard let name = index["name"] as? String,
                  index["unique"] as? Int == 1,
                  index["partial"] as? Int ?? 0 == 0,
                  index["origin"] as? String != "pk" else { continue }

            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            let indexColumns = try await queryRaw("PRAGMA index_info(\"\(escaped)\")")
                .compactMap { $0["name"] as? String }

            if !indexColumns.isEmpty, !targets.contains(indexColumns) {
                targets.append(indexColumns)
            }
        }

        tableConflictTargetsCache[table] = targets
        return targets
    }

    /// Upsert arbitrary rows. Only columns existing in the table are written.
    /// If the table has a synced_at column and it's missing, it's set to now().
    ///
    /// This used to emit `REPLACE INTO`, which is not an upsert: on a constraint violation it
    /// DELETEs the conflicting row and inserts a new one. With `PRAGMA foreign_keys = ON` — set in
    /// `openDatabase()` — that delete runs the `ON DELETE CASCADE` actions, and 21 tables cascade
    /// from `profiles(id)`. Since `profiles` is the first table the remote pull upserts, a single
    /// `REPLACE INTO profiles` wiped the user's entire local database on every sync; the pull then
    /// refilled 13 of those tables from the server and left the rest empty. `ON CONFLICT DO UPDATE`
    /// mutates the existing row in place, so nothing cascades.
    @MainActor
    func upsert(table: String, rows: [[String: Any]]) async throws {
        try validateTableName(table)  // Phase 5: SQL injection prevention
        guard !rows.isEmpty else { return }
        let safeRows = rows.map(SQLSendableRecord.init(raw:))
        let cols = try await columns(for: table)
        guard !cols.isEmpty else { return }

        let hasSyncedAt = cols.contains("synced_at")
        let now = ISO8601DateFormatter().string(from: Date())
        let targets = try await conflictTargets(for: table)

        for row in safeRows {
            var filtered: [String: Any] = [:]
            for col in cols {
                if let v = row.raw[col], !(v is NSNull) {
                    filtered[col] = v
                }
            }
            if hasSyncedAt, filtered["synced_at"] == nil {
                filtered["synced_at"] = now
            }

            let keys = Array(filtered.keys)
            guard !keys.isEmpty else { continue }

            let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
            let colsJoined = keys.joined(separator: ",")

            // One clause per conflict target, so a row colliding on a natural key (say
            // list_items' UNIQUE(list_id, media_id, media_type)) still converges instead of
            // raising — which is what REPLACE used to buy us, without the delete.
            var sql = "INSERT INTO \(table) (\(colsJoined)) VALUES (\(placeholders))"
            for target in targets {
                let assignments = keys
                    .filter { !target.contains($0) }
                    .map { "\($0)=excluded.\($0)" }
                    .joined(separator: ",")
                let onConflict = "ON CONFLICT(\(target.joined(separator: ",")))"
                sql += assignments.isEmpty
                    ? " \(onConflict) DO NOTHING"
                    : " \(onConflict) DO UPDATE SET \(assignments)"
            }

            let params = keys.map { filtered[$0] ?? NSNull() }
            try await executeWrite(sql, parameters: params)
        }
    }
    
    /// Query and decode to Codable type
    func query<T: Decodable>(_ sql: String, parameters: [Any] = []) async throws -> [T] {
        let rows = try await queryRaw(sql, parameters: parameters)
        let data = try JSONSerialization.data(withJSONObject: rows)
        return try JSONDecoder().decode([T].self, from: data)
    }
    
    // MARK: - Transaction Support

    /// Runs `body` inside a single, genuinely atomic transaction (STAB-002).
    ///
    /// The old version was `async` and called `execute("BEGIN")`, then `await operations()`, then
    /// `execute("COMMIT")` — three *separate* hops on the shared serial `writerQueue`, with `await`
    /// suspension points between them. Because SQLite transactions are per-connection and every
    /// other writer uses the same `db`, another task's write could be scheduled on the writer queue
    /// *between* BEGIN and COMMIT, landing inside this transaction; and a ROLLBACK then either
    /// undid their write too or, worse, the interleaving corrupted the boundaries — the demonstrated
    /// "ROLLBACK non annulla nulla".
    ///
    /// Now BEGIN, the whole body, and COMMIT/ROLLBACK run in one `writerQueue.sync` block. The queue
    /// is serial, so nothing else can interleave, and there are no suspension points inside. The
    /// body is synchronous and writes through the passed `SQLiteTransaction`, whose statements run
    /// directly on the writer thread (no re-dispatch, which would deadlock or escape the block).
    func transaction(_ body: (SQLiteTransaction) throws -> Void) throws {
        try writerQueue.sync {
            guard let db = self.db else { throw SQLiteError.notConnected }

            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            do {
                try body(SQLiteTransaction(db))
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    let commitError = String(cString: sqlite3_errmsg(db))
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    throw SQLiteError.queryFailed(commitError)
                }
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }
    
    // MARK: - CRUD Helpers
    
    /// Insert a record and return the rowid
    func insert(_ table: String, values: [String: Any]) async throws -> Int64 {
        try validateTableName(table)  // Phase 5: SQL injection prevention
        try validateColumnNames(values.keys)  // Phase 5 (1.10): column identifiers
        let columns = values.keys.joined(separator: ", ")
        let placeholders = values.keys.map { _ in "?" }.joined(separator: ", ")
        let sql = "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))"
        
        let parameters = Array(values.values).map(SQLSendableValue.init(raw:))
        
        return try await withCheckedThrowingContinuation { continuation in
            writerQueue.async { [weak self, parameters] in
                guard let self = self else {
                    continuation.resume(throwing: SQLiteError.notConnected)
                    return
                }

                var statement: OpaquePointer?

                guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                    let error = String(cString: sqlite3_errmsg(self.db))
                    continuation.resume(throwing: SQLiteError.queryFailed(error))
                    return
                }

                defer { sqlite3_finalize(statement) }

                // Bind parameters
                for (index, param) in parameters.enumerated() {
                    Self.bindValue(param.raw, to: statement, at: Int32(index + 1))
                }

                if sqlite3_step(statement) == SQLITE_DONE {
                    let rowid = sqlite3_last_insert_rowid(self.db)
                    continuation.resume(returning: rowid)
                } else {
                    let error = String(cString: sqlite3_errmsg(self.db))
                    continuation.resume(throwing: SQLiteError.queryFailed(error))
                }
            }
        }
    }
    
    /// Update records
    func update(_ table: String, values: [String: Any], where condition: String, parameters: [Any] = []) async throws {
        try validateTableName(table)  // Phase 5: SQL injection prevention
        try validateColumnNames(values.keys)  // Phase 5 (1.10): column identifiers
        let setClause = values.keys.map { "\($0) = ?" }.joined(separator: ", ")
        let sql = "UPDATE \(table) SET \(setClause) WHERE \(condition)"
        
        let valueParams = Array(values.values)
        let allParams = valueParams + parameters

        try await executeWrite(sql, parameters: allParams)
    }
    
    /// Delete records (soft delete by default)
    func delete(_ table: String, where condition: String, parameters: [Any] = [], hard: Bool = false) async throws {
        try validateTableName(table)  // Phase 5: SQL injection prevention
        if hard {
            let sql = "DELETE FROM \(table) WHERE \(condition)"
            try await executeWrite(sql, parameters: parameters)
        } else {
            // Soft delete
            let sql = "UPDATE \(table) SET deleted_at = datetime('now') WHERE \(condition)"
            try await executeWrite(sql, parameters: parameters)
        }
    }

    /// Select records
    func select<T: Decodable>(
        _ table: String,
        where condition: String? = nil,
        parameters: [Any] = [],
        orderBy: String? = nil,
        limit: Int? = nil
    ) async throws -> [T] {
        try validateTableName(table)  // Phase 5: SQL injection prevention
        var sql = "SELECT * FROM \(table)"
        
        if let condition = condition {
            sql += " WHERE \(condition)"
        }
        
        if let orderBy = orderBy {
            sql += " ORDER BY \(orderBy)"
        }
        
        if let limit = limit {
            sql += " LIMIT \(limit)"
        }
        
        return try await query(sql, parameters: parameters)
    }
    
    // MARK: - Utility Methods
    
    /// Count records
    func count(_ table: String, where condition: String? = nil, parameters: [Any] = []) async throws -> Int {
        try validateTableName(table)  // Phase 5: SQL injection prevention (gap: era non validato)
        var sql = "SELECT COUNT(*) as count FROM \(table)"
        
        if let condition = condition {
            sql += " WHERE \(condition)"
        }
        
        let result = try await queryRaw(sql, parameters: parameters)
        return result.first?["count"] as? Int ?? 0
    }
    
    /// Check if record exists
    func exists(_ table: String, where condition: String, parameters: [Any] = []) async throws -> Bool {
        let count = try await self.count(table, where: condition, parameters: parameters)
        return count > 0
    }
    
    /// Generate UUID
    func generateUUID() -> String {
        return UUID().uuidString.lowercased()
    }
    
    /// Get last insert rowid
    func lastInsertRowId() -> Int64 {
        return sqlite3_last_insert_rowid(db)
    }
    
    // MARK: - Batch Operations
    
    @MainActor
    func performBatchInsert(table: String, records: [[String: Any]]) async -> Bool {
        guard !records.isEmpty else { return true }

        // Phase 5 (1.10): table + column identifiers interpolati → valida prima.
        // Questo metodo non è throwing: su input invalido logga e ritorna false.
        guard SQLiteTable.isValid(table) else {
            Logger.error("[SQLite] SQL injection attempt blocked: invalid table '\(table)'")
            return false
        }
        guard records[0].keys.allSatisfy(Self.isValidColumnIdentifier) else {
            Logger.error("[SQLite] SQL injection attempt blocked: invalid column in batch insert into '\(table)'")
            return false
        }

        let recordCols = Array(records[0].keys)
        let columns = recordCols.joined(separator: ", ")
        let placeholders = "(" + Array(repeating: "?", count: recordCols.count).joined(separator: ", ") + ")"

        // Was `INSERT OR REPLACE`, which deletes the conflicting row and re-inserts. On list_items
        // that resurrected soft-deleted rows (the incoming record carries no deleted_at, so the
        // fresh row defaults it to NULL) and, more dangerously in general, fires ON DELETE CASCADE.
        // Same fix and same conflict-target derivation as `upsert()`: mutate in place, and never
        // touch columns the caller didn't provide — so a soft-deleted item stays deleted.
        let targets = (try? await conflictTargets(for: table)) ?? []
        var query = "INSERT INTO \(table) (\(columns)) VALUES \(placeholders)"
        for target in targets {
            let assignments = recordCols
                .filter { !target.contains($0) }
                .map { "\($0)=excluded.\($0)" }
                .joined(separator: ", ")
            let onConflict = "ON CONFLICT(\(target.joined(separator: ", ")))"
            query += assignments.isEmpty ? " \(onConflict) DO NOTHING" : " \(onConflict) DO UPDATE SET \(assignments)"
        }

        let safeRecords = records.map(SQLSendableRecord.init(raw:))
        
        return await withCheckedContinuation { continuation in
            writerQueue.async { [weak self, safeRecords] in
                guard let self = self, let db = self.db else {
                    continuation.resume(returning: false)
                    return
                }
                
                var success = true
                var statement: OpaquePointer?
                
                // Use C-API directly for transaction
                let beginResult = sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
                if beginResult != SQLITE_OK {
                    let error = String(cString: sqlite3_errmsg(db))
                    Logger.error("Batch insert transaction begin failed: \(error)")
                    continuation.resume(returning: false)
                    return
                }
                
                do {
                    // Prepare statement once
                    if sqlite3_prepare_v2(db, query, -1, &statement, nil) != SQLITE_OK {
                         let error = String(cString: sqlite3_errmsg(db))
                         Logger.error("Batch insert prepare failed: \(error)")
                         sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                         continuation.resume(returning: false)
                         return
                    }
                    
                    // Sort keys to ensure order matches columns
                    let sortedKeys = safeRecords[0].raw.keys
                    
                    for record in safeRecords {
                        // Reset statement for reuse
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        
                        // Bind parameters
                        for (index, key) in sortedKeys.enumerated() {
                            // Use existing helper to bind values
                            // index is 1-based in SQLite
                            Self.bindValue(record.raw[key] ?? NSNull(), to: statement, at: Int32(index + 1))
                        }
                        
                        if sqlite3_step(statement) != SQLITE_DONE {
                            let error = String(cString: sqlite3_errmsg(db))
                            Logger.error("Batch insert step failed: \(error)")
                            throw SQLiteError.queryFailed(error)
                        }
                    }
                    
                    sqlite3_finalize(statement)
                    
                    // Commit transaction
                    if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
                         let error = String(cString: sqlite3_errmsg(db))
                         Logger.error("Batch insert commit failed: \(error)")
                         throw SQLiteError.transactionFailed
                    }
                    
                } catch {
                    Logger.error("Batch insert failed: \(error)")
                    sqlite3_finalize(statement)
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    success = false
                }
                
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Helper Methods
    
    nonisolated static func bindValue(_ value: Any, to statement: OpaquePointer?, at index: Int32) {
        switch value {
        case let val as String:
            sqlite3_bind_text(statement, index, (val as NSString).utf8String, -1, nil)
        case let val as Int:
            sqlite3_bind_int64(statement, index, Int64(val))
        case let val as Int64:
            sqlite3_bind_int64(statement, index, val)
        case let val as Double:
            sqlite3_bind_double(statement, index, val)
        case let val as Bool:
            sqlite3_bind_int(statement, index, val ? 1 : 0)
        case let val as Data:
            _ = val.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(val.count), nil)
            }
        case let val as Date:
            let formatter = ISO8601DateFormatter()
            let dateString = formatter.string(from: val)
            sqlite3_bind_text(statement, index, (dateString as NSString).utf8String, -1, nil)
        case is NSNull:
            sqlite3_bind_null(statement, index)
        default:
            // Try to encode as JSON
            if let data = try? JSONEncoder().encode(AnyEncodable(value)),
               let string = String(data: data, encoding: .utf8) {
                sqlite3_bind_text(statement, index, (string as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }
    }
    
    private func getValue(from statement: OpaquePointer?, at index: Int32) -> Any? {
        let type = sqlite3_column_type(statement, index)
        
        switch type {
        case SQLITE_INTEGER:
            return Int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return sqlite3_column_double(statement, index)
        case SQLITE_TEXT:
            return String(cString: sqlite3_column_text(statement, index))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
            let count = sqlite3_column_bytes(statement, index)
            return Data(bytes: bytes, count: Int(count))
        case SQLITE_NULL:
            return nil
        default:
            return nil
        }
    }
}


// MARK: - Transaction Context

/// The synchronous write surface handed to `SQLiteService.transaction(_:)`. Every call runs
/// directly on the writer thread inside the transaction's single `writerQueue.sync` block, so the
/// statements are part of the same atomic unit and nothing else can interleave (STAB-002).
///
/// It intentionally does NOT re-enter `writerQueue` (that would deadlock) and offers only the
/// operations the five transaction call sites actually use: raw `execute`, `insert`, `delete`.
final class SQLiteTransaction {
    private let db: OpaquePointer

    fileprivate init(_ db: OpaquePointer) { self.db = db }

    /// Run a statement. Throws on prepare/step failure so the enclosing transaction rolls back.
    func execute(_ sql: String, parameters: [Any] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, param) in parameters.enumerated() {
            SQLiteService.bindValue(param, to: statement, at: Int32(index + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func insert(_ table: String, values: [String: Any]) throws {
        guard SQLiteTable.isValid(table) else { throw SQLiteError.invalidTableName(table) }
        for key in values.keys where !SQLiteService.isValidColumnIdentifier(key) {
            throw SQLiteError.invalidColumnName(key)
        }
        let columns = values.keys.joined(separator: ", ")
        let placeholders = values.keys.map { _ in "?" }.joined(separator: ", ")
        try execute("INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))",
                    parameters: Array(values.values))
    }

    func delete(_ table: String, where condition: String, parameters: [Any] = [], hard: Bool = false) throws {
        guard SQLiteTable.isValid(table) else { throw SQLiteError.invalidTableName(table) }
        let sql = hard
            ? "DELETE FROM \(table) WHERE \(condition)"
            : "UPDATE \(table) SET deleted_at = datetime('now') WHERE \(condition)"
        try execute(sql, parameters: parameters)
    }
}

// MARK: - Helper Structures

private struct AnyEncodable: Encodable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if let value = value as? String {
            try container.encode(value)
        } else if let value = value as? Int {
            try container.encode(value)
        } else if let value = value as? Double {
            try container.encode(value)
        } else if let value = value as? Bool {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}

// MARK: - Error Types

enum SQLiteError: LocalizedError {
    case notConnected
    case queryFailed(String)
    case invalidData
    case transactionFailed
    case invalidTableName(String)  // Phase 5: SQL injection prevention
    case invalidColumnName(String) // Phase 5: SQL injection prevention

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SQLite database not connected"
        case .queryFailed(let message):
            return "Query failed: \(message)"
        case .invalidData:
            return "Invalid data format"
        case .transactionFailed:
            return "Transaction failed"
        case .invalidTableName(let table):
            return "Invalid table name: \(table)"
        case .invalidColumnName(let column):
            return "Invalid column name: \(column)"
        }
    }
}

// Writes serialized through `writerQueue`; reads dispatched to concurrent `readerQueue`.
// Mark as @unchecked Sendable for use inside @Sendable closures.
extension SQLiteService: @unchecked Sendable {}
