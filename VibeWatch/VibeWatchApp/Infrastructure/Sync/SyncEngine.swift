import Foundation
import Combine

// MARK: - SyncEngineProtocol

/// Protocol defining the unified sync engine interface.
/// Enables testability through dependency injection and mocking.
public protocol SyncEngineProtocol: AnyObject {
    /// Whether a sync operation is currently in progress
    var isSyncing: Bool { get }

    /// Timestamp of the last successful sync
    var lastSyncAt: Date? { get }

    /// Number of pending operations in the outbox
    var pendingOperationsCount: Int { get }

    /// Last error encountered during sync (if any)
    var lastError: String? { get }

    /// Queue an operation for later sync to the remote server.
    /// - Parameters:
    ///   - table: The database table name
    ///   - operationType: The type of operation (INSERT, UPDATE, UPSERT, DELETE)
    ///   - recordId: The unique identifier for the record
    ///   - payload: The data payload to sync
    ///   - dependsOn: Optional ID of another operation that must complete first
    func queueOperation(
        table: String,
        operationType: String,
        recordId: String,
        payload: [String: Any],
        dependsOn: Int?
    ) async throws

    /// Perform a full bidirectional sync (push then pull).
    /// - Parameter trigger: The reason this sync was triggered
    func performFullSync(trigger: SyncTrigger) async

    /// Push only pending changes to the remote server.
    /// Typically used when going to background.
    func pushPendingChanges() async

    /// Pull only changes from the remote server.
    /// Typically used for pull-to-refresh.
    func pullFromRemote() async
}

// MARK: - SyncEngine Implementation

/// Unified sync engine that manages ALL sync operations for the app.
/// Replaces the dual SyncManager/SyncWorker systems with a single entry point.
///
/// Key Features:
/// - Single `isSyncing` flag with proper locking
/// - Unified exponential backoff: [60s, 5min, 15min, 1hr, 4hr]
/// - Dependency graph support via `depends_on_id`
/// - Schema error handling (PGRST205 blocking)
/// - Notifications for sync lifecycle events
@MainActor
public final class SyncEngine: ObservableObject, SyncEngineProtocol {

    // MARK: - Singleton

    public static let shared = SyncEngine()

    // MARK: - Published State

    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSyncAt: Date?
    @Published public private(set) var pendingOperationsCount: Int = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var isOnline: Bool = true

    // MARK: - Dependencies

    private let sqliteService: SQLiteService
    private let networkMonitor: NetworkMonitor
    private let deviceId: String

    // MARK: - Configuration

    /// Conflict resolver for handling local/remote conflicts during pull
    private let conflictResolver: ConflictResolverProtocol

    /// Maximum number of retry attempts before marking an operation as stuck
    private let maxRetries = 5

    /// Number of operations to process in each batch
    private let batchSize = 50

    /// Exponential backoff schedule in seconds: 60s, 5min, 15min, 1hr, 4hr
    private let backoffSchedule: [TimeInterval] = [60, 300, 900, 3600, 14400]

    /// Interval between periodic sync attempts (60 seconds)
    private let periodicSyncInterval: TimeInterval = 60

    /// Minimum time in background before triggering full sync on resume (2 minutes)
    private let backgroundThreshold: TimeInterval = 120

    // MARK: - Internal State

    private var syncTimer: Timer?
    private var lastBackgroundTime: Date?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Notification Names

    public static let syncStartedNotification = Notification.Name("SyncEngine.syncStarted")
    public static let syncCompletedNotification = Notification.Name("SyncEngine.syncCompleted")
    public static let syncFailedNotification = Notification.Name("SyncEngine.syncFailed")

    // MARK: - Initialization

    private init(
        sqliteService: SQLiteService = .shared,
        networkMonitor: NetworkMonitor = .shared,
        conflictResolver: ConflictResolverProtocol = ConflictResolver.shared
    ) {
        self.sqliteService = sqliteService
        self.networkMonitor = networkMonitor
        self.conflictResolver = conflictResolver

        // Load or create device ID
        if let savedDeviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") {
            self.deviceId = savedDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            UserDefaults.standard.set(newDeviceId, forKey: "deviceIdentifier")
            self.deviceId = newDeviceId
        }

        // Load last sync time
        if let lastSync = UserDefaults.standard.object(forKey: "SyncEngine.lastSyncTimestamp") as? Date {
            self.lastSyncAt = lastSync
        }

        Logger.info("[SyncEngine] Initialized with device ID: \(deviceId)")

        setupNetworkObserver()
    }

    // MARK: - Setup

    private func setupNetworkObserver() {
        // Monitor network status changes
        networkMonitor.$isConnected
            .removeDuplicates()
            .sink { [weak self] isConnected in
                self?.isOnline = isConnected
                if isConnected {
                    Task { @MainActor [weak self] in
                        await self?.handleNetworkRestored()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle Management

    /// Start periodic sync timer. Call this when app becomes active.
    public func startPeriodicSync() {
        stopPeriodicSync()

        syncTimer = Timer.scheduledTimer(withTimeInterval: periodicSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performFullSync(trigger: .periodic)
            }
        }

        Logger.info("[SyncEngine] Periodic sync started (every \(Int(periodicSyncInterval))s)")

        // Initial sync
        Task {
            await performFullSync(trigger: .appLaunch)
        }
    }

    /// Stop periodic sync timer. Call this when app goes to background.
    public func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    /// Record when app goes to background for foreground resume logic.
    public func recordBackgroundEntry() {
        lastBackgroundTime = Date()
        Logger.debug("[SyncEngine] Recorded background entry")
    }

    /// Handle app returning to foreground.
    public func handleForegroundResume() async {
        let shouldFullSync: Bool
        if let backgroundTime = lastBackgroundTime {
            let elapsed = Date().timeIntervalSince(backgroundTime)
            shouldFullSync = elapsed > backgroundThreshold
            Logger.debug("[SyncEngine] Background duration: \(Int(elapsed))s, threshold: \(Int(backgroundThreshold))s")
        } else {
            shouldFullSync = true
        }

        if shouldFullSync {
            await performFullSync(trigger: .foregroundResume)
        } else {
            await pushPendingChanges()
        }
    }

    private func handleNetworkRestored() async {
        Logger.info("[SyncEngine] Network restored - syncing pending changes")
        await performFullSync(trigger: .networkRestored)
    }

    // MARK: - Queue Operation

    public func queueOperation(
        table: String,
        operationType: String,
        recordId: String,
        payload: [String: Any],
        dependsOn: Int? = nil
    ) async throws {
        let operationId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        // Serialize payload to JSON
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"

        // Get current user ID
        let userId = AuthService.shared.currentUser?.id ?? "anonymous"

        // Build SQL with optional depends_on_id
        let sql: String
        let parameters: [Any]

        if let dependsOnId = dependsOn {
            sql = """
                INSERT INTO sync_outbox (
                    operation_id, user_id, table_name, operation_type,
                    record_id, payload, status, created_at, depends_on_id
                ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
            """
            parameters = [operationId, userId, table, operationType, recordId, payloadString, now, dependsOnId]
        } else {
            sql = """
                INSERT INTO sync_outbox (
                    operation_id, user_id, table_name, operation_type,
                    record_id, payload, status, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
            """
            parameters = [operationId, userId, table, operationType, recordId, payloadString, now]
        }

        let success = sqliteService.execute(sql, parameters: parameters)

        if success {
            await updatePendingCount()
            Logger.debug("[SyncEngine] Queued \(operationType) on \(table) for record \(recordId)")

            // Attempt immediate sync if online
            if networkMonitor.isConnected {
                await pushPendingChanges()
            }
        } else {
            Logger.error("[SyncEngine] Failed to queue sync operation")
            throw SyncEngineError.queueFailed
        }
    }

    // MARK: - Full Sync

    public func performFullSync(trigger: SyncTrigger) async {
        guard !isSyncing else {
            Logger.debug("[SyncEngine] Sync already in progress, skipping (\(trigger.logDescription))")
            return
        }

        guard networkMonitor.isConnected else {
            Logger.debug("[SyncEngine] Offline, skipping sync (\(trigger.logDescription))")
            return
        }

        Logger.info("[SyncEngine] Starting \(trigger.shouldPerformFullSync ? "full" : "partial") sync (\(trigger.logDescription))")

        isSyncing = true
        postNotification(SyncEngine.syncStartedNotification, trigger: trigger)

        defer {
            isSyncing = false
        }

        do {
            // Push pending changes first
            if trigger.shouldPushChanges {
                await pushPendingChangesInternal()
            }

            // Pull remote changes
            if trigger.shouldPullChanges {
                await pullFromRemoteInternal()
            }

            // Update state
            let now = Date()
            lastSyncAt = now
            UserDefaults.standard.set(now, forKey: "SyncEngine.lastSyncTimestamp")
            lastError = nil

            postNotification(SyncEngine.syncCompletedNotification, trigger: trigger)
            Logger.info("[SyncEngine] Sync completed successfully (\(trigger.logDescription))")

        } catch {
            lastError = error.localizedDescription
            postNotification(SyncEngine.syncFailedNotification, trigger: trigger, error: error)
            Logger.error("[SyncEngine] Sync failed (\(trigger.logDescription))", error: error)
        }
    }

    // MARK: - Push Changes

    public func pushPendingChanges() async {
        guard !isSyncing else {
            Logger.debug("[SyncEngine] Push skipped - sync in progress")
            return
        }

        guard networkMonitor.isConnected else {
            Logger.debug("[SyncEngine] Push skipped - offline")
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        await pushPendingChangesInternal()
    }

    private func pushPendingChangesInternal() async {
        do {
            // Unblock previously blocked schema-missing operations
            unblockSchemaErrorOperations()

            // Fetch pending operations respecting dependencies
            let operations = try await fetchPendingOperations()

            guard !operations.isEmpty else {
                Logger.debug("[SyncEngine] No pending operations to push")
                return
            }

            Logger.info("[SyncEngine] Pushing \(operations.count) pending operations")

            var successCount = 0
            var failCount = 0

            // Process operations in order (respecting dependencies)
            for operation in operations {
                do {
                    try await executeOperation(operation)
                    try await markOperationCompleted(operationId: operation.operationId)
                    successCount += 1
                } catch {
                    let errorMessage = error.localizedDescription

                    // Check for schema missing error (PGRST205)
                    if isSchemaError(errorMessage) {
                        try? await markOperationBlocked(operationId: operation.operationId, error: errorMessage)
                        Logger.warning("[SyncEngine] Blocked operation (schema missing): \(operation.tableName)")
                    } else {
                        try? await incrementRetryCount(operationId: operation.operationId, error: errorMessage)
                        Logger.warning("[SyncEngine] Operation failed: \(operation.tableName) - \(errorMessage)")
                    }
                    failCount += 1
                }
            }

            await updatePendingCount()
            Logger.info("[SyncEngine] Push complete: \(successCount) succeeded, \(failCount) failed")

        } catch {
            Logger.error("[SyncEngine] Push failed", error: error)
        }
    }

    // MARK: - Pull Changes

    public func pullFromRemote() async {
        guard !isSyncing else {
            Logger.debug("[SyncEngine] Pull skipped - sync in progress")
            return
        }

        guard networkMonitor.isConnected else {
            Logger.debug("[SyncEngine] Pull skipped - offline")
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        await pullFromRemoteInternal()
    }

    private func pullFromRemoteInternal() async {
        guard let userId = AuthService.shared.currentUser?.id else {
            Logger.debug("[SyncEngine] Pull skipped - not authenticated")
            return
        }

        Logger.info("[SyncEngine] Pulling remote changes for user \(userId)")

        // Tables to sync (user-scoped)
        let userTables = [
            "profiles",
            "lists",
            "list_items",
            "user_preferences",
            "movie_reactions",
            "user_gamification",
            "user_badges",
            "user_daily_challenges",
            "xp_transactions",
            "user_clip_history",
            "user_clip_signals",
            "ai_conversation_history",
            "global_discovery_filters",
            "device_info"
        ]

        for table in userTables {
            do {
                try await pullTableWithConflictResolution(name: table, userId: userId)
                Logger.debug("[SyncEngine] Pulled \(table)")
            } catch {
                Logger.warning("[SyncEngine] Failed to pull \(table): \(error.localizedDescription)")
            }
        }

        Logger.info("[SyncEngine] Pull complete")
    }

    /// Pulls a table from remote with conflict resolution applied.
    ///
    /// For each remote record, checks if a local record exists and uses
    /// the appropriate conflict resolution strategy to merge them.
    private func pullTableWithConflictResolution(name: String, userId: String) async throws {
        guard let client = SupabaseService.shared.client else {
            throw SyncEngineError.notAuthenticated
        }

        // Fetch remote records
        var query = client.from(name).select("*")
        if name == "profiles" {
            query = query.eq("id", value: userId)
        } else {
            query = query.eq("user_id", value: userId)
        }

        let data = try await query.execute().data
        guard let remoteRows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        let strategy = TableConflictMapping.strategy(for: name)
        var resolvedRows: [[String: Any]] = []
        var conflictsResolved = 0

        for remoteRow in remoteRows {
            // Normalize remote row
            let normalizedRemote = normalizeRow(remoteRow, for: name)

            // Get the record ID
            guard let recordId = getRecordId(from: normalizedRemote, table: name) else {
                resolvedRows.append(normalizedRemote)
                continue
            }

            // Check for local record
            if let localRow = await fetchLocalRecord(table: name, id: recordId) {
                // Conflict exists - resolve it
                let resolved = conflictResolver.resolve(
                    table: name,
                    local: localRow,
                    remote: normalizedRemote
                )

                resolvedRows.append(resolved.record)

                if resolved.wasModified {
                    conflictsResolved += 1
                    Logger.debug("[SyncEngine] Resolved conflict in \(name) using \(resolved.strategyUsed.rawValue): \(resolved.source.rawValue)")
                }
            } else {
                // No local record - just use remote
                resolvedRows.append(normalizedRemote)
            }
        }

        // Upsert resolved records to local database
        if !resolvedRows.isEmpty {
            try await sqliteService.upsert(table: name, rows: resolvedRows)
        }

        if conflictsResolved > 0 {
            Logger.info("[SyncEngine] Resolved \(conflictsResolved) conflicts in \(name) using \(strategy.rawValue) strategy")
        }
    }

    /// Fetches a local record by ID for conflict resolution.
    private func fetchLocalRecord(table: String, id: String) async -> [String: Any]? {
        let idColumn = getPrimaryKeyColumn(for: table)
        let sql = "SELECT * FROM \(table) WHERE \(idColumn) = ? LIMIT 1"

        do {
            let rows = try await sqliteService.queryRaw(sql, parameters: [id])
            return rows.first
        } catch {
            return nil
        }
    }

    /// Gets the primary key column name for a table.
    private func getPrimaryKeyColumn(for table: String) -> String {
        switch table {
        case "user_gamification":
            return "user_id"
        case "device_info":
            return "device_id"
        case "global_discovery_filters":
            return "user_id"
        default:
            return "id"
        }
    }

    /// Gets the record ID from a row based on table type.
    private func getRecordId(from row: [String: Any], table: String) -> String? {
        let keyColumn = getPrimaryKeyColumn(for: table)
        if let id = row[keyColumn] {
            return String(describing: id)
        }
        return nil
    }

    /// Normalizes a row for storage (handles media_type, JSON arrays, etc.).
    private func normalizeRow(_ row: [String: Any], for table: String) -> [String: Any] {
        var normalized = row

        // Ensure media_type is valid
        if table == "clips" || table == "list_items" {
            if let mt = normalized["media_type"] as? String, !["movie", "tv"].contains(mt) {
                normalized["media_type"] = "movie"
            }
        }

        // Convert Postgres arrays to JSON strings
        let arrayFields = ["genres", "actors", "keywords", "origin_country"]
        for field in arrayFields {
            if let arr = normalized[field] as? [Any] {
                if let data = try? JSONSerialization.data(withJSONObject: arr),
                   let str = String(data: data, encoding: .utf8) {
                    normalized[field] = str
                }
            }
        }

        return normalized
    }

    // MARK: - Operation Execution

    private func executeOperation(_ operation: SyncOutboxOperation) async throws {
        // Build mutation for Supabase
        var record = operation.payload
        if record["id"] == nil {
            record["id"] = operation.recordId
        }

        // Sanitize media_type for tables that require it
        if ["clips", "list_items", "movie_reactions"].contains(operation.tableName) {
            if let mt = record["media_type"] as? String, !["movie", "tv"].contains(mt) {
                record["media_type"] = "movie"
            }
        }

        let mutation: [String: Any] = [
            "op": operation.operationType.uppercased(),
            "table": operation.tableName,
            "id": operation.recordId,
            "record": record
        ]

        try await SupabaseService.shared.applyMutations([mutation])
    }

    // MARK: - Database Operations

    private func fetchPendingOperations() async throws -> [SyncOutboxOperation] {
        // Query pending operations that:
        // 1. Have status = pending or failed
        // 2. Haven't exceeded retry limit
        // 3. Are past their next_retry_at time (if set)
        // 4. Have no unresolved dependencies
        let sql = """
            SELECT * FROM sync_outbox
            WHERE status IN ('pending', 'failed')
              AND attempts < ?
              AND (next_retry_at IS NULL OR next_retry_at <= datetime('now'))
              AND (depends_on_id IS NULL
                   OR depends_on_id IN (
                     SELECT id FROM sync_outbox WHERE status = 'completed'
                   ))
            ORDER BY id ASC
            LIMIT ?
        """

        let rows = try await sqliteService.queryRaw(sql, parameters: [maxRetries, batchSize])
        return rows.compactMap { SyncOutboxOperation(row: $0) }
    }

    private func markOperationCompleted(operationId: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
            UPDATE sync_outbox
            SET status = 'completed', synced_at = ?
            WHERE operation_id = ?
        """
        let success = sqliteService.execute(sql, parameters: [now, operationId])
        if !success {
            throw SyncEngineError.databaseError
        }
    }

    private func markOperationBlocked(operationId: String, error: String) async throws {
        let sql = """
            UPDATE sync_outbox
            SET status = 'blocked',
                last_error = ?,
                next_retry_at = NULL
            WHERE operation_id = ?
        """
        let success = sqliteService.execute(sql, parameters: [error, operationId])
        if !success {
            throw SyncEngineError.databaseError
        }
    }

    private func incrementRetryCount(operationId: String, error: String) async throws {
        let attempts = try await getAttemptCount(operationId: operationId)
        let nextRetry = calculateNextRetryTime(attempts: attempts)
        let nextRetryString = ISO8601DateFormatter().string(from: nextRetry)

        let sql = """
            UPDATE sync_outbox
            SET attempts = attempts + 1,
                last_error = ?,
                next_retry_at = ?
            WHERE operation_id = ?
        """
        let success = sqliteService.execute(sql, parameters: [error, nextRetryString, operationId])
        if !success {
            throw SyncEngineError.databaseError
        }
    }

    private func getAttemptCount(operationId: String) async throws -> Int {
        let sql = "SELECT attempts FROM sync_outbox WHERE operation_id = ?"
        let rows = try await sqliteService.queryRaw(sql, parameters: [operationId])
        return rows.first?["attempts"] as? Int ?? 0
    }

    private func calculateNextRetryTime(attempts: Int) -> Date {
        let index = min(attempts, backoffSchedule.count - 1)
        let delay = backoffSchedule[index]
        return Date().addingTimeInterval(delay)
    }

    private func unblockSchemaErrorOperations() {
        let sql = """
            UPDATE sync_outbox
            SET status = 'pending',
                attempts = 0,
                last_error = NULL
            WHERE status = 'blocked' AND last_error LIKE '%PGRST205%'
        """
        _ = sqliteService.execute(sql)
    }

    private func isSchemaError(_ error: String) -> Bool {
        // PostgREST error when a table isn't present in the schema cache
        error.contains("PGRST205") ||
        (error.localizedCaseInsensitiveContains("schema cache") &&
         error.localizedCaseInsensitiveContains("Could not find the table"))
    }

    private func updatePendingCount() async {
        do {
            let sql = "SELECT COUNT(*) as count FROM sync_outbox WHERE status IN ('pending', 'failed')"
            let rows = try await sqliteService.queryRaw(sql)
            pendingOperationsCount = rows.first?["count"] as? Int ?? 0
        } catch {
            Logger.error("[SyncEngine] Failed to update pending count", error: error)
        }
    }

    // MARK: - Notifications

    private func postNotification(_ name: Notification.Name, trigger: SyncTrigger, error: Error? = nil) {
        var userInfo: [String: Any] = ["trigger": trigger.rawValue]
        if let error = error {
            userInfo["error"] = error.localizedDescription
        }
        NotificationCenter.default.post(name: name, object: self, userInfo: userInfo)
    }

    // MARK: - Debug / Admin

    /// Get pending operations for debugging
    public func getPendingOperations() async -> [[String: Any]] {
        do {
            let rows = try await sqliteService.queryRaw("""
                SELECT id, table_name, operation_type, record_id, attempts, status, last_error
                FROM sync_outbox
                WHERE status IN ('pending', 'failed', 'blocked')
                ORDER BY created_at DESC
                LIMIT 50
            """)
            return rows
        } catch {
            Logger.warning("[SyncEngine] Failed to get pending operations: \(error.localizedDescription)")
            return []
        }
    }

    /// Reset blocked/stuck operations (admin action)
    public func resetBlockedOperations() async {
        let sql = """
            UPDATE sync_outbox
            SET status = 'pending',
                attempts = 0,
                next_retry_at = NULL,
                last_error = NULL
            WHERE status IN ('blocked', 'stuck')
        """
        _ = sqliteService.execute(sql)
        await updatePendingCount()
        Logger.info("[SyncEngine] Reset all blocked operations")
    }

    /// Clear completed operations older than specified days
    public func clearOldCompletedOperations(olderThanDays: Int = 7) async {
        let sql = """
            DELETE FROM sync_outbox
            WHERE status = 'completed'
              AND synced_at < datetime('now', '-\(olderThanDays) days')
        """
        _ = sqliteService.execute(sql)
        Logger.info("[SyncEngine] Cleared completed operations older than \(olderThanDays) days")
    }
}

// MARK: - SyncOutboxOperation

/// Internal model for operations read from the sync_outbox table
private struct SyncOutboxOperation {
    let id: Int
    let operationId: String
    let userId: String
    let tableName: String
    let operationType: String
    let recordId: String
    let payload: [String: Any]
    let status: String
    let attempts: Int
    let dependsOnId: Int?
    let nextRetryAt: Date?

    init?(row: [String: Any]) {
        guard
            let id = row["id"] as? Int,
            let operationId = row["operation_id"] as? String,
            let userId = row["user_id"] as? String,
            let tableName = row["table_name"] as? String,
            let operationType = row["operation_type"] as? String,
            let recordId = row["record_id"] as? String,
            let payloadString = row["payload"] as? String,
            let payloadData = payloadString.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
            let status = row["status"] as? String
        else {
            return nil
        }

        self.id = id
        self.operationId = operationId
        self.userId = userId
        self.tableName = tableName
        self.operationType = operationType
        self.recordId = recordId
        self.payload = payload
        self.status = status
        self.attempts = row["attempts"] as? Int ?? 0
        self.dependsOnId = row["depends_on_id"] as? Int

        if let retryString = row["next_retry_at"] as? String {
            self.nextRetryAt = ISO8601DateFormatter().date(from: retryString)
        } else {
            self.nextRetryAt = nil
        }
    }
}

// MARK: - SyncEngineError

public enum SyncEngineError: LocalizedError {
    case queueFailed
    case databaseError
    case networkError
    case notAuthenticated
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .queueFailed:
            return "Failed to queue sync operation"
        case .databaseError:
            return "Database operation failed during sync"
        case .networkError:
            return "Network error during sync"
        case .notAuthenticated:
            return "User must be authenticated to sync"
        case .operationFailed(let message):
            return "Sync operation failed: \(message)"
        }
    }
}

// MARK: - Notification.Name Extensions

public extension Notification.Name {
    static let syncStarted = SyncEngine.syncStartedNotification
    static let syncEngineCompleted = SyncEngine.syncCompletedNotification
    static let syncFailed = SyncEngine.syncFailedNotification
}
