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

    // Wrappers to allow capturing dynamic SQLite values in @Sendable contexts.
    private struct SQLSendableValue: @unchecked Sendable { let raw: Any }
    private struct SQLSendableRecord: @unchecked Sendable { var raw: [String: Any] }

    /// Validate table name to prevent SQL injection (Phase 5 Security)
    private func validateTableName(_ table: String) throws {
        guard SQLiteTable.isValid(table) else {
            Logger.error("[SQLite] SQL injection attempt blocked: invalid table '\(table)'")
            throw SQLiteError.invalidTableName(table)
        }
    }
    
    private init() {
        // Store in app's Documents directory
        let fileManager = FileManager.default
        let urls = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        dbPath = urls[0].appendingPathComponent("vibewatch_local.sqlite").path
        
        Logger.info("[SQLite] Database path: \(dbPath)")
        
        openDatabase()
        createTables()
        checkInitialCacheState()
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
        let sql = "SELECT COUNT(*) FROM personalized_discovery LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            hasPersonalizedDiscoveryCache = sqlite3_column_int(stmt, 0) > 0
        }
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
        
        for table in tables {
            execute(table)
        }
        
        // Initialize metadata
        execute("""
            INSERT OR IGNORE INTO app_metadata (key_name, value_text) VALUES
            ('app_install_date', datetime('now')),
            ('db_schema_version', '1.0.0'),
            ('last_full_sync', NULL)
        """)
        
        Logger.info("[SQLite] All tables created")

        // Run migrations
        runMigrations()

        // Run personalization migrations (Phase 1)
        runPersonalizationMigrations()
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
        let latestVersion = 4
        
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

        // Re-enable foreign keys
        execute("PRAGMA foreign_keys = ON")
        
        // Mark migration as complete
        execute("INSERT OR REPLACE INTO app_metadata (key_name, value_text) VALUES ('migration_version', '\(latestVersion)')")
        Logger.info("[SQLite] Migrations complete - now at version \(latestVersion)")
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
                bind(param, to: statement, at: Int32(index + 1))
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
    
    /// Query and return rows as dictionaries
    nonisolated(nonsending)
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

                // Bind parameters
                for (index, param) in safeParameters.enumerated() {
                    self.bind(param.raw, to: statement, at: Int32(index + 1))
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

    /// REPLACE INTO upsert for arbitrary rows. Only columns existing in the table are written.
    /// If the table has a synced_at column and it's missing, it's set to now().
    nonisolated(nonsending)
    func upsert(table: String, rows: [[String: Any]]) async throws {
        try validateTableName(table)  // Phase 5: SQL injection prevention
        guard !rows.isEmpty else { return }
        let safeRows = rows.map(SQLSendableRecord.init(raw:))
        let cols = try await columns(for: table)
        guard !cols.isEmpty else { return }

        let hasSyncedAt = cols.contains("synced_at")
        let now = ISO8601DateFormatter().string(from: Date())

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
            let sql = "REPLACE INTO \(table) (\(colsJoined)) VALUES (\(placeholders))"
            let params = keys.map { filtered[$0] ?? NSNull() }
            _ = try await queryRaw(sql, parameters: params)
        }
    }
    
    /// Query and decode to Codable type
    nonisolated(nonsending)
    func query<T: Decodable>(_ sql: String, parameters: [Any] = []) async throws -> [T] {
        let rows = try await queryRaw(sql, parameters: parameters)
        let data = try JSONSerialization.data(withJSONObject: rows)
        return try JSONDecoder().decode([T].self, from: data)
    }
    
    // MARK: - Transaction Support
    
    func transaction(_ operations: @Sendable () async throws -> Void) async throws {
        try await DatabaseUtilities.executeInTransaction {
            self.execute("BEGIN TRANSACTION")
            do {
                try await operations()
                self.execute("COMMIT")
            } catch {
                self.execute("ROLLBACK")
                throw error
            }
        }
    }
    
    // MARK: - CRUD Helpers
    
    /// Insert a record and return the rowid
    nonisolated(nonsending)
    func insert(_ table: String, values: [String: Any]) async throws -> Int64 {
        try validateTableName(table)  // Phase 5: SQL injection prevention
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
                    self.bind(param.raw, to: statement, at: Int32(index + 1))
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
    nonisolated(nonsending)
    func update(_ table: String, values: [String: Any], where condition: String, parameters: [Any] = []) async throws {
        try validateTableName(table)  // Phase 5: SQL injection prevention
        let setClause = values.keys.map { "\($0) = ?" }.joined(separator: ", ")
        let sql = "UPDATE \(table) SET \(setClause) WHERE \(condition)"
        
        let valueParams = Array(values.values)
        let allParams = valueParams + parameters
        
        _ = try await queryRaw(sql, parameters: allParams)
    }
    
    /// Delete records (soft delete by default)
    nonisolated(nonsending)
    func delete(_ table: String, where condition: String, parameters: [Any] = [], hard: Bool = false) async throws {
        try validateTableName(table)  // Phase 5: SQL injection prevention
        if hard {
            let sql = "DELETE FROM \(table) WHERE \(condition)"
            _ = try await queryRaw(sql, parameters: parameters)
        } else {
            // Soft delete
            let sql = "UPDATE \(table) SET deleted_at = datetime('now') WHERE \(condition)"
            _ = try await queryRaw(sql, parameters: parameters)
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
        
        let columns = records[0].keys.joined(separator: ", ")
        let placeholders = "(" + Array(repeating: "?", count: records[0].keys.count).joined(separator: ", ") + ")"
        let query = "INSERT OR REPLACE INTO \(table) (\(columns)) VALUES \(placeholders)"
        
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
                    print("❌ Batch insert transaction begin failed: \(error)")
                    continuation.resume(returning: false)
                    return
                }
                
                do {
                    // Prepare statement once
                    if sqlite3_prepare_v2(db, query, -1, &statement, nil) != SQLITE_OK {
                         let error = String(cString: sqlite3_errmsg(db))
                         print("❌ Batch insert prepare failed: \(error)")
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
                            self.bind(record.raw[key] ?? NSNull(), to: statement, at: Int32(index + 1))
                        }
                        
                        if sqlite3_step(statement) != SQLITE_DONE {
                            let error = String(cString: sqlite3_errmsg(db))
                            print("❌ Batch insert step failed: \(error)")
                            throw SQLiteError.queryFailed(error)
                        }
                    }
                    
                    sqlite3_finalize(statement)
                    
                    // Commit transaction
                    if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
                         let error = String(cString: sqlite3_errmsg(db))
                         print("❌ Batch insert commit failed: \(error)")
                         throw SQLiteError.transactionFailed
                    }
                    
                } catch {
                    print("❌ Batch insert failed: \(error)")
                    sqlite3_finalize(statement)
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    success = false
                }
                
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Helper Methods
    
    private func bind(_ value: Any, to statement: OpaquePointer?, at index: Int32) {
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

// MARK: - Table Creation

extension SQLiteService {
    private func createClipsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS clips (
          id TEXT PRIMARY KEY,
          clip_id TEXT UNIQUE NOT NULL,
          video_id TEXT NOT NULL,
          title TEXT NOT NULL,
          description TEXT,
          video_url TEXT NOT NULL,
          thumbnail_url TEXT,
          movie_id INTEGER,
          tv_show_id INTEGER,
          media_type TEXT,
          genres TEXT,
          actors TEXT,
          mood TEXT,
          keywords TEXT,
          likes INTEGER DEFAULT 0,
          comments INTEGER DEFAULT 0,
          views INTEGER DEFAULT 0,
          youtube_views INTEGER,
          tmdb_rating REAL,
          quality_score REAL,
          is_active INTEGER DEFAULT 1,
          is_premium INTEGER DEFAULT 0,
          created_at TEXT DEFAULT (datetime('now')),
          fetched_at TEXT DEFAULT (datetime('now')),
          last_served_at TEXT,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_clips_active ON clips(is_active, deleted_at);
        CREATE INDEX IF NOT EXISTS idx_clips_media_type ON clips(media_type);
        CREATE INDEX IF NOT EXISTS idx_clips_quality ON clips(quality_score DESC);
        CREATE INDEX IF NOT EXISTS idx_clips_created ON clips(created_at DESC);
        """
    }
    
    private func createDiscoveryCacheTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS discovery_cache (
          id TEXT PRIMARY KEY,
          content_type TEXT NOT NULL,
          tmdb_id INTEGER NOT NULL,
          title TEXT NOT NULL,
          overview TEXT,
          poster_path TEXT,
          backdrop_path TEXT,
          vote_average REAL,
          release_date TEXT,
          genres TEXT,
          cached_at TEXT DEFAULT (datetime('now')),
          expires_at TEXT NOT NULL,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          UNIQUE(content_type, tmdb_id)
        );
        CREATE INDEX IF NOT EXISTS idx_discovery_content_type ON discovery_cache(content_type);
        CREATE INDEX IF NOT EXISTS idx_discovery_expires ON discovery_cache(expires_at);
        """
    }
    
    private func createMediaDetailsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS media_details_cache (
          tmdb_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          title TEXT NOT NULL,
          overview TEXT,
          poster_path TEXT,
          backdrop_path TEXT,
          cached_at TEXT DEFAULT (datetime('now')),
          expires_at TEXT NOT NULL,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          PRIMARY KEY (tmdb_id, media_type)
        );
        """
    }

    private func createDetailCacheTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS detail_cache (
          id TEXT PRIMARY KEY,
          media_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          title TEXT NOT NULL,
          overview TEXT,
          poster_path TEXT,
          backdrop_path TEXT,
          release_date TEXT,
          vote_average REAL,
          runtime INTEGER,
          genres TEXT,
          credits_json TEXT,
          videos_json TEXT,
          providers_json TEXT,
          similar_json TEXT,
          imdb_id TEXT,
          cached_at TEXT DEFAULT (datetime('now')),
          expires_at TEXT NOT NULL,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          UNIQUE(media_id, media_type)
        );
        CREATE INDEX IF NOT EXISTS idx_detail_cache_media ON detail_cache(media_id, media_type);
        CREATE INDEX IF NOT EXISTS idx_detail_cache_expires ON detail_cache(expires_at);
        """
    }
    
    private func createTrailersTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS trailers_cache (
          tmdb_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          youtube_id TEXT NOT NULL,
          trailer_type TEXT,
          name TEXT,
          cached_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          PRIMARY KEY (tmdb_id, media_type, youtube_id)
        );
        """
    }
    
    private func createProfilesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS profiles (
          id TEXT PRIMARY KEY,
          email TEXT UNIQUE,
          display_name TEXT,
          avatar_url TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT
        );
        """
    }
    
    private func createListsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS lists (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          name TEXT NOT NULL,
          description TEXT,
          type TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_lists_user_id ON lists(user_id);
        CREATE INDEX IF NOT EXISTS idx_lists_deleted ON lists(deleted_at);
        """
    }
    
    private func createListItemsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS list_items (
          id TEXT PRIMARY KEY,
          list_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          media_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          title TEXT NOT NULL,
          poster_path TEXT,
          runtime INTEGER,
          vote_average REAL,
          vote_count INTEGER,
          origin_country TEXT,
          release_date TEXT,
          genres TEXT,
          overview TEXT,
          added_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(list_id, media_id, media_type),
          FOREIGN KEY (list_id) REFERENCES lists(id) ON DELETE CASCADE,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_list_items_list_id ON list_items(list_id);
        CREATE INDEX IF NOT EXISTS idx_list_items_user_id ON list_items(user_id);
        """
    }
    
    private func createUserClipHistoryTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_clip_history (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          clip_id TEXT NOT NULL,
          watched_at TEXT DEFAULT (datetime('now')),
          watch_duration REAL,
          total_duration REAL,
          completion_rate REAL,
          liked INTEGER DEFAULT 0,
          commented INTEGER DEFAULT 0,
          shared INTEGER DEFAULT 0,
          added_to_list INTEGER DEFAULT 0,
          engagement_score REAL,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(user_id, clip_id),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_history_user_id ON user_clip_history(user_id);
        CREATE INDEX IF NOT EXISTS idx_clip_history_watched_at ON user_clip_history(watched_at DESC);
        """
    }

    private func createUserClipSignalsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_clip_signals (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          clip_id TEXT NOT NULL,
          signal_type TEXT NOT NULL,
          signal_value REAL,
          source TEXT,
          position INTEGER,
          session_id TEXT,
          occurred_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_signals_user_id ON user_clip_signals(user_id);
        CREATE INDEX IF NOT EXISTS idx_clip_signals_clip_id ON user_clip_signals(clip_id);
        """
    }
    
    private func createUserPreferencesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_preferences (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          preference_type TEXT NOT NULL,
          preference_id TEXT NOT NULL,
          preference_name TEXT,
          score REAL DEFAULT 0,
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(user_id, preference_type, preference_id),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_preferences_user_id ON user_preferences(user_id);
        """
    }
    
    private func createUserDailyQuotaTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_daily_quota (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          clips_watched_today INTEGER DEFAULT 0,
          last_reset_at TEXT DEFAULT (datetime('now')),
          is_pro INTEGER DEFAULT 0,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          deleted_at TEXT,
          synced_at TEXT,
          UNIQUE(user_id, device_id),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        """
    }
    
    private func createUserAITokenUsageTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_ai_token_usage (
          id TEXT,
          user_id TEXT PRIMARY KEY,
          tokens_used_today INTEGER DEFAULT 0,
          last_reset_at TEXT,
          usage_day TEXT,
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT
        );
        """
    }

    
    private func createSyncOutboxTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS sync_outbox (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          operation_id TEXT UNIQUE NOT NULL,
          user_id TEXT NOT NULL,
          table_name TEXT NOT NULL,
          operation_type TEXT NOT NULL,
          record_id TEXT NOT NULL,
          payload TEXT NOT NULL,
          status TEXT DEFAULT 'pending',
          attempts INTEGER DEFAULT 0,
          max_attempts INTEGER DEFAULT 5,
          created_at TEXT DEFAULT (datetime('now')),
          next_retry_at TEXT,
          synced_at TEXT,
          last_error TEXT,
          depends_on_id INTEGER,
          FOREIGN KEY (depends_on_id) REFERENCES sync_outbox(id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_outbox_status ON sync_outbox(status, next_retry_at);
        CREATE INDEX IF NOT EXISTS idx_outbox_user_id ON sync_outbox(user_id);
        """
    }
    
    private func createSyncLogTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS sync_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sync_batch_id TEXT NOT NULL,
          operation_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          table_name TEXT NOT NULL,
          operation_type TEXT NOT NULL,
          status TEXT NOT NULL,
          error_message TEXT,
          synced_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_sync_log_batch ON sync_log(sync_batch_id);
        CREATE INDEX IF NOT EXISTS idx_sync_log_timestamp ON sync_log(synced_at DESC);
        """
    }
    
    private func createDeviceInfoTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS device_info (
          device_id TEXT PRIMARY KEY,
          user_id TEXT,
          device_name TEXT,
          platform TEXT,
          app_version TEXT,
          last_sync_at TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now'))
        );
        """
    }
    
    private func createAppMetadataTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS app_metadata (
          key_name TEXT PRIMARY KEY,
          value_text TEXT,
          value_number REAL,
          value_boolean INTEGER,
          value_json TEXT,
          updated_at TEXT DEFAULT (datetime('now'))
        );
        """
    }
    
    // MARK: - Reactions & Comments Tables
    
    private func createMovieReactionsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS movie_reactions (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          media_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          reaction_type TEXT NOT NULL,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          UNIQUE(user_id, media_id, media_type),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_movie_reactions_user ON movie_reactions(user_id);
        CREATE INDEX IF NOT EXISTS idx_movie_reactions_media ON movie_reactions(media_id, media_type);
        """
    }
    
    private func createMovieReactionCountsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS movie_reaction_counts (
          media_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          like_count INTEGER DEFAULT 0,
          dislike_count INTEGER DEFAULT 0,
          updated_at TEXT DEFAULT (datetime('now')),
          PRIMARY KEY (media_id, media_type)
        );
        """
    }
    
    private func createClipReactionsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS clip_reactions (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          clip_id TEXT NOT NULL,
          reaction_type TEXT NOT NULL DEFAULT 'like',
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          UNIQUE(user_id, clip_id, reaction_type),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_reactions_user ON clip_reactions(user_id);
        CREATE INDEX IF NOT EXISTS idx_clip_reactions_clip ON clip_reactions(clip_id);
        """
    }
    
    private func createClipCommentsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS clip_comments (
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
          synced_at TEXT,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE,
          FOREIGN KEY (parent_comment_id) REFERENCES clip_comments(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_comments_clip ON clip_comments(clip_id, deleted_at);
        CREATE INDEX IF NOT EXISTS idx_clip_comments_parent ON clip_comments(parent_comment_id);
        CREATE INDEX IF NOT EXISTS idx_clip_comments_user ON clip_comments(user_id);
        """
    }
    
    private func createClipCommentLikesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS clip_comment_likes (
          id TEXT PRIMARY KEY,
          comment_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          created_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          UNIQUE(user_id, comment_id),
          FOREIGN KEY (comment_id) REFERENCES clip_comments(id) ON DELETE CASCADE,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_comment_likes_comment ON clip_comment_likes(comment_id);
        CREATE INDEX IF NOT EXISTS idx_clip_comment_likes_user ON clip_comment_likes(user_id);
        CREATE INDEX IF NOT EXISTS idx_clip_comment_likes_user_comment ON clip_comment_likes(user_id, comment_id);
        """
    }

    // MARK: - Gamification Tables

    private func createUserGamificationTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_gamification (
          user_id TEXT PRIMARY KEY,
          total_xp INTEGER DEFAULT 0,
          current_level INTEGER DEFAULT 1,
          current_streak INTEGER DEFAULT 0,
          longest_streak INTEGER DEFAULT 0,
          last_activity_date TEXT,
          streak_freezes_remaining INTEGER DEFAULT 0,
          streak_freezes_used_this_week INTEGER DEFAULT 0,
          week_start_date TEXT,
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        """
    }

    private func createUserBadgesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_badges (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          badge_id TEXT NOT NULL,
          progress INTEGER DEFAULT 0,
          target INTEGER NOT NULL,
          unlocked_at TEXT,
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          UNIQUE(user_id, badge_id),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_user_badges_user ON user_badges(user_id);
        CREATE INDEX IF NOT EXISTS idx_user_badges_unlocked ON user_badges(unlocked_at);
        """
    }

    private func createUserDailyChallengesTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS user_daily_challenges (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          challenge_date TEXT NOT NULL,
          challenge_type TEXT NOT NULL,
          challenge_description TEXT,
          target INTEGER NOT NULL,
          progress INTEGER DEFAULT 0,
          completed_at TEXT,
          xp_reward INTEGER DEFAULT 0,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          synced_at TEXT,
          UNIQUE(user_id, challenge_date),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_daily_challenges_user ON user_daily_challenges(user_id);
        CREATE INDEX IF NOT EXISTS idx_daily_challenges_date ON user_daily_challenges(challenge_date);
        """
    }

    private func createXPTransactionsTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS xp_transactions (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          action_type TEXT NOT NULL,
          base_xp INTEGER NOT NULL,
          multiplier REAL DEFAULT 1.0,
          streak_bonus REAL DEFAULT 0.0,
          total_xp INTEGER NOT NULL,
          source TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_xp_transactions_user ON xp_transactions(user_id);
        CREATE INDEX IF NOT EXISTS idx_xp_transactions_created ON xp_transactions(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_xp_transactions_action ON xp_transactions(action_type);
        """
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
        }
    }
}

// Writes serialized through `writerQueue`; reads dispatched to concurrent `readerQueue`.
// Mark as @unchecked Sendable for use inside @Sendable closures.
extension SQLiteService: @unchecked Sendable {}
