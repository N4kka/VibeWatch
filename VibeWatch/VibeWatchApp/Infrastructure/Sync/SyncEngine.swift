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

    /// The sync state machine managing sync lifecycle
    public let stateMachine: SyncStateMachine

    /// Whether a sync operation is currently in progress (derived from state machine)
    @Published public private(set) var isSyncing = false

    @Published public private(set) var lastSyncAt: Date?
    @Published public private(set) var pendingOperationsCount: Int = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var isOnline: Bool = true

    /// The current sync state (forwarded from state machine)
    public var syncState: SyncState {
        stateMachine.currentState
    }

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

    /// Interval between periodic sync attempts.
    ///
    /// Fase 4 (3.2 — batteria): era 60s, alzato a 5 min come SOLO fallback. Il push non
    /// dipende più da questo timer per la latenza: `queueOperation` fa già un push
    /// immediato quando online (event-driven), e foreground-resume / network-restored
    /// triggerano una sync. Inoltre il push periodico skippa subito se l'outbox è vuota
    /// (pushPendingChangesInternal). Allungare l'intervallo taglia i wakeup CPU periodici
    /// a parità di comportamento osservabile.
    private let periodicSyncInterval: TimeInterval = 300

    /// Minimum time in background before triggering full sync on resume (2 minutes)
    private let backgroundThreshold: TimeInterval = 120

    nonisolated static func normalizedMutationRecord(
        table: String,
        operationType: String,
        recordId: String,
        payload: [String: Any]
    ) -> [String: Any] {
        var record = payload
        if record["id"] == nil {
            record["id"] = recordId
        }

        if ["clips", "list_items", "movie_reactions"].contains(table),
           let mediaType = record["media_type"] as? String,
           !["movie", "tv"].contains(mediaType) {
            record["media_type"] = "movie"
        }

        let op = operationType.uppercased()
        if table == "list_items", op == "INSERT" || op == "UPDATE" || op == "UPSERT" {
            let now = ISO8601DateFormatter().string(from: Date())
            let addedAt = timestampString(record["added_at"]) ?? timestampString(record["created_at"]) ?? now
            record["added_at"] = timestampString(record["added_at"]) ?? addedAt
            record["created_at"] = timestampString(record["created_at"]) ?? addedAt
            record["updated_at"] = timestampString(record["updated_at"]) ?? now
        }

        return record
    }

    /// Recovers outbox operations that have exhausted their retries, for **every** table — not
    /// just list_items (STAB-007). Safe to reset unconditionally because every push goes through
    /// `apply_mutations`, which now dead-letters deterministic per-item failures server-side
    /// (logging them to `sync_rejected_mutations` and returning 200). So a client op that stays
    /// failing did so on transport/5xx errors, which are transient and worth retrying on a later
    /// run. Also catches the pre-existing backlog: legacy exhausted ops sit at status
    /// 'pending'/'failed' with high `attempts`, from before exhaustion set 'stuck'.
    /// 'blocked' (schema-missing) rows are left to their own PGRST205 recovery.
    nonisolated static func recoverStuckOperationsSQL(maxRetries: Int) -> String {
        """
            UPDATE sync_outbox
            SET status = 'pending',
                attempts = 0,
                next_retry_at = NULL,
                last_error = NULL
            WHERE status = 'stuck'
               OR (status IN ('pending', 'failed') AND attempts >= \(maxRetries))
        """
    }

    nonisolated static func recoverRetryableListItemOperationsSQL(maxRetries: Int) -> String {
        """
            UPDATE sync_outbox
            SET status = 'pending',
                attempts = 0,
                next_retry_at = NULL,
                last_error = NULL
            WHERE table_name = 'list_items'
              AND operation_type IN ('INSERT', 'UPDATE', 'UPSERT')
              AND status IN ('pending', 'failed', 'blocked', 'stuck')
              AND (
                    attempts >= \(maxRetries)
                    OR next_retry_at IS NOT NULL
                    OR payload NOT LIKE '%"created_at"%'
                  )
        """
    }

    private nonisolated static func timestampString(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        return nil
    }

    // MARK: - Internal State

    private var syncTimer: Timer?
    private var lastBackgroundTime: Date?
    private var cancellables = Set<AnyCancellable>()

    /// Tracks the state before suspension for proper resume
    private var stateBeforeSuspension: SyncState?

    // MARK: - Notification Names

    public static let syncStartedNotification = Notification.Name("SyncEngine.syncStarted")
    public static let syncCompletedNotification = Notification.Name("SyncEngine.syncCompleted")
    public static let syncFailedNotification = Notification.Name("SyncEngine.syncFailed")

    // MARK: - Initialization

    private init(
        sqliteService: SQLiteService = .shared,
        networkMonitor: NetworkMonitor = .shared,
        conflictResolver: ConflictResolverProtocol = ConflictResolver.shared,
        stateMachine: SyncStateMachine? = nil
    ) {
        self.sqliteService = sqliteService
        self.networkMonitor = networkMonitor
        self.conflictResolver = conflictResolver
        self.stateMachine = stateMachine ?? SyncStateMachine()

        // Load or create device ID
        self.deviceId = DeviceIdentity.installation

        // Load last sync time
        if let lastSync = UserDefaults.standard.object(forKey: "SyncEngine.lastSyncTimestamp") as? Date {
            self.lastSyncAt = lastSync
        }

        Logger.info("[SyncEngine] Initialized with device ID: \(deviceId)")

        setupNetworkObserver()
        setupStateMachineObserver()
    }

    // MARK: - Setup

    private func setupNetworkObserver() {
        // Monitor network status changes
        networkMonitor.$isConnected
            .removeDuplicates()
            .sink { [weak self] isConnected in
                guard let self = self else { return }
                self.isOnline = isConnected
                if isConnected {
                    Task { @MainActor [weak self] in
                        await self?.handleNetworkRestored()
                    }
                } else {
                    // Network lost - transition to offline if not already
                    self.handleNetworkLost()
                }
            }
            .store(in: &cancellables)
    }

    private func setupStateMachineObserver() {
        // Keep isSyncing in sync with state machine
        stateMachine.$currentState
            .map { $0.isSyncing }
            .removeDuplicates()
            .assign(to: &$isSyncing)
    }

    private func handleNetworkLost() {
        // Only transition to offline if we're in a state that should go offline
        switch stateMachine.currentState {
        case .idle:
            stateMachine.goOffline(reason: "Network connectivity lost")
        case .syncing:
            // Will be handled by the sync operation failure
            break
        default:
            break
        }
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
        stateBeforeSuspension = stateMachine.currentState
        stateMachine.suspend(reason: "App entering background")
        Logger.debug("[SyncEngine] Recorded background entry, state was: \(stateBeforeSuspension?.logDescription ?? "unknown")")
    }

    /// Handle app returning to foreground.
    public func handleForegroundResume() async {
        // Resume from suspended state
        let previousState = stateBeforeSuspension
        stateBeforeSuspension = nil

        let shouldFullSync: Bool
        if let backgroundTime = lastBackgroundTime {
            let elapsed = Date().timeIntervalSince(backgroundTime)
            shouldFullSync = elapsed > backgroundThreshold
            Logger.debug("[SyncEngine] Background duration: \(Int(elapsed))s, threshold: \(Int(backgroundThreshold))s")
        } else {
            shouldFullSync = true
        }

        // Determine the resume state based on network and previous state
        let resumeState: SyncState
        if !networkMonitor.isConnected {
            resumeState = .offline
        } else if case .error(let err, let retryable) = previousState {
            // Preserve error state if not retryable
            resumeState = retryable ? .idle : .error(err, retryable: false)
        } else {
            resumeState = .idle
        }

        stateMachine.resume(to: resumeState, reason: "App returned to foreground")

        if resumeState == .idle {
            if shouldFullSync {
                await performFullSync(trigger: .foregroundResume)
            } else {
                await pushPendingChanges()
            }
        }
    }

    private func handleNetworkRestored() async {
        Logger.info("[SyncEngine] Network restored - syncing pending changes")

        // Transition from offline to idle (or stay in current state if not offline)
        if case .offline = stateMachine.currentState {
            stateMachine.goOnline(reason: "Network connectivity restored")
        }

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
        let normalizedPayload = Self.normalizedMutationRecord(
            table: table,
            operationType: operationType,
            recordId: recordId,
            payload: payload
        )

        // Serialize payload to JSON
        let payloadData = try JSONSerialization.data(withJSONObject: normalizedPayload)
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
        // Check if we can start a sync using state machine
        guard stateMachine.canTransition(to: .syncing(.fullSync)) else {
            Logger.debug("[SyncEngine] Cannot start sync in current state: \(stateMachine.currentState.logDescription) (\(trigger.logDescription))")
            return
        }

        guard networkMonitor.isConnected else {
            Logger.debug("[SyncEngine] Offline, skipping sync (\(trigger.logDescription))")
            if stateMachine.currentState != .offline {
                stateMachine.goOffline(reason: "Network unavailable for sync")
            }
            return
        }

        // Determine the operation type based on trigger
        let operation: SyncOperationType = trigger.shouldPerformFullSync ? .fullSync :
            (trigger.shouldPushChanges && trigger.shouldPullChanges ? .fullSync :
             trigger.shouldPushChanges ? .push : .pull)

        Logger.info("[SyncEngine] Starting \(operation.logDescription) (\(trigger.logDescription))")

        // Transition to syncing state
        guard stateMachine.startSync(operation, reason: trigger.logDescription) else {
            Logger.warning("[SyncEngine] Failed to transition to syncing state")
            return
        }

        postNotification(SyncEngine.syncStartedNotification, trigger: trigger)

        // Neither half throws — they absorb their own errors and report them — so this used to sit
        // inside a do/catch whose catch could never run. A sync where every table and every queued
        // operation failed still reached completeSync(), logged "completed successfully", advanced
        // lastSyncAt and cleared lastError, and syncFailedNotification was never posted anywhere in
        // the app. The outcomes below are what makes a failure observable.
        var outcome = SyncOutcome()

        if trigger.shouldPushChanges {
            outcome.merge(await pushPendingChangesInternal())
        }

        if trigger.shouldPullChanges {
            outcome.merge(await pullFromRemoteInternal())
        }

        guard !outcome.hasFailures else {
            let stateError = SyncStateError.partialFailure(failed: outcome.failed, total: outcome.attempted)
            lastError = stateError.localizedDescription

            // A sync that failed because the network went away is offline, not broken.
            if networkMonitor.isConnected {
                stateMachine.failSync(with: stateError, reason: "Sync failed: \(lastError ?? "")")
            } else {
                stateMachine.goOffline(reason: "Network lost during sync")
            }

            postNotification(SyncEngine.syncFailedNotification, trigger: trigger, error: stateError)
            Logger.error("[SyncEngine] Sync failed (\(trigger.logDescription)): \(lastError ?? "")")
            return
        }

        // lastSyncAt only advances on a clean sync: it is what tells us how stale the device is.
        let now = Date()
        lastSyncAt = now
        UserDefaults.standard.set(now, forKey: "SyncEngine.lastSyncTimestamp")
        lastError = nil

        stateMachine.completeSync(reason: "Sync completed for \(trigger.logDescription)")

        postNotification(SyncEngine.syncCompletedNotification, trigger: trigger)
        Logger.info("[SyncEngine] Sync completed successfully (\(trigger.logDescription))")
    }

    /// What one half of a sync actually managed to do.
    struct SyncOutcome {
        /// Operations or tables the sync tried to process.
        private(set) var attempted = 0
        /// How many of those failed.
        private(set) var failed = 0

        var hasFailures: Bool { failed > 0 }

        mutating func recordSuccess() { attempted += 1 }

        mutating func recordFailure() {
            attempted += 1
            failed += 1
        }

        mutating func merge(_ other: SyncOutcome) {
            attempted += other.attempted
            failed += other.failed
        }
    }

    // MARK: - Push Changes

    public func pushPendingChanges() async {
        guard stateMachine.canTransition(to: .syncing(.push)) else {
            Logger.debug("[SyncEngine] Push skipped - cannot transition from \(stateMachine.currentState.logDescription)")
            return
        }

        guard networkMonitor.isConnected else {
            Logger.debug("[SyncEngine] Push skipped - offline")
            return
        }

        // Remote sync is an authenticated-only feature: anonymous users are local-only
        // (see OVERVIEW tier model). The hardened apply_mutations rejects unauthenticated
        // callers, so attempting a push here would only generate failed retries.
        guard AuthService.shared.currentUser != nil else {
            Logger.debug("[SyncEngine] Push skipped - not authenticated (local-only mode)")
            return
        }

        guard stateMachine.startSync(.push, reason: "Pushing pending changes") else {
            Logger.debug("[SyncEngine] Push skipped - failed to start sync")
            return
        }

        let outcome = await pushPendingChangesInternal()

        // Complete the sync if we're still in syncing state
        if stateMachine.currentState.isSyncing {
            if outcome.hasFailures {
                stateMachine.failSync(
                    with: .partialFailure(failed: outcome.failed, total: outcome.attempted),
                    reason: "Push failed"
                )
            } else {
                stateMachine.completeSync(reason: "Push completed")
            }
        }
    }

    @discardableResult
    private func pushPendingChangesInternal() async -> SyncOutcome {
        var outcome = SyncOutcome()

        do {
            // Unblock previously blocked schema-missing operations
            unblockSchemaErrorOperations()

            // Fetch pending operations respecting dependencies
            let operations = try await fetchPendingOperations()

            guard !operations.isEmpty else {
                Logger.debug("[SyncEngine] No pending operations to push")
                return outcome
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
                    outcome.recordSuccess()
                } catch {
                    let errorMessage = error.localizedDescription

                    // Check for schema missing error (PGRST205)
                    if isSchemaError(errorMessage) {
                        do {
                            try await markOperationBlocked(operationId: operation.operationId, error: errorMessage)
                        } catch {
                            Logger.error("[SyncEngine] Failed to mark operation as blocked: \(error.localizedDescription)")
                        }
                        Logger.warning("[SyncEngine] Blocked operation (schema missing): \(operation.tableName)")
                    } else {
                        do {
                            try await incrementRetryCount(operationId: operation.operationId, error: errorMessage)
                        } catch {
                            Logger.error("[SyncEngine] Failed to increment retry count: \(error.localizedDescription)")
                        }
                        Logger.warning("[SyncEngine] Operation failed: \(operation.tableName) - \(errorMessage)")
                    }
                    failCount += 1
                    outcome.recordFailure()
                }
            }

            await updatePendingCount()
            Logger.info("[SyncEngine] Push complete: \(successCount) succeeded, \(failCount) failed")

        } catch {
            // Reaching here means the outbox itself could not be read: nothing was pushed.
            outcome.recordFailure()
            Logger.error("[SyncEngine] Push failed", error: error)
        }

        return outcome
    }

    // MARK: - Pull Changes

    public func pullFromRemote() async {
        guard stateMachine.canTransition(to: .syncing(.pull)) else {
            Logger.debug("[SyncEngine] Pull skipped - cannot transition from \(stateMachine.currentState.logDescription)")
            return
        }

        guard networkMonitor.isConnected else {
            Logger.debug("[SyncEngine] Pull skipped - offline")
            return
        }

        guard stateMachine.startSync(.pull, reason: "Pulling remote changes") else {
            Logger.debug("[SyncEngine] Pull skipped - failed to start sync")
            return
        }

        let outcome = await pullFromRemoteInternal()

        // Complete the sync if we're still in syncing state
        if stateMachine.currentState.isSyncing {
            if outcome.hasFailures {
                stateMachine.failSync(
                    with: .partialFailure(failed: outcome.failed, total: outcome.attempted),
                    reason: "Pull failed"
                )
            } else {
                stateMachine.completeSync(reason: "Pull completed")
            }
        }
    }

    @discardableResult
    private func pullFromRemoteInternal() async -> SyncOutcome {
        var outcome = SyncOutcome()

        guard let userId = AuthService.shared.currentUser?.id else {
            Logger.debug("[SyncEngine] Pull skipped - not authenticated")
            return outcome
        }

        Logger.info("[SyncEngine] Pulling remote changes for user \(userId)")

        // Tables to sync (user-scoped)
        let userTables = [
            "profiles",
            "lists",
            "list_items",
            "user_preferences",
            // unified_user_preferences now has a working push path again (STAB-010), so pull it too
            // to keep the discovery-personalization store consistent across devices.
            "unified_user_preferences",
            // "movie_reactions" was removed from this list because the table did not exist on
            // Supabase and pulling it failed on every sync. The table now exists, with RLS scoped
            // to auth.uid() and a natural key of (user_id, media_id, media_type), so the pull is
            // back. Its aggregate companion, movie_reaction_counts, is deliberately NOT pulled:
            // it is global rather than user-scoped, and a trigger maintains it server-side.
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
                outcome.recordSuccess()
                Logger.debug("[SyncEngine] Pulled \(table)")
            } catch {
                outcome.recordFailure()
                Logger.warning("[SyncEngine] Failed to pull \(table): \(error.localizedDescription)")
            }
        }

        Logger.info("[SyncEngine] Pull complete: \(outcome.attempted - outcome.failed) of \(outcome.attempted) tables")
        return outcome
    }

    /// Pulls a table from remote with conflict resolution applied.
    ///
    /// For each remote record, checks if a local record exists and uses
    /// the appropriate conflict resolution strategy to merge them.
    ///
    /// The fetch is paginated (see `SyncPagination`): an unbounded `select("*")` over a table the
    /// size of an imported TV Time history either times out against the 8s `statement_timeout` or,
    /// on a project with `db-max-rows` set, comes back truncated without saying so.
    private func pullTableWithConflictResolution(name: String, userId: String) async throws {
        guard let client = SupabaseService.shared.client else {
            throw SyncEngineError.notAuthenticated
        }

        let keyColumn = getPrimaryKeyColumn(for: name)
        var totalConflictsResolved = 0

        let rowsPulled = try await SyncPagination.walk(
            table: name,
            fetchPage: { offset, limit in
                var query = client.from(name).select("*")
                if name == "profiles" {
                    query = query.eq("id", value: userId)
                } else {
                    query = query.eq("user_id", value: userId)
                }

                // Ordering is what makes paging correct, not just deterministic output. Without an
                // ORDER BY, Postgres may return rows in a different order for each request, so
                // two windows over the same table can overlap and miss rows at the same time. The
                // primary key is unique within the filtered set, which is what a stable sort needs.
                let data = try await query
                    .order(keyColumn, ascending: true)
                    .range(from: offset, to: offset + limit - 1)
                    .execute()
                    .data

                return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            },
            handlePage: { remoteRows in
                let resolved = await self.resolvePage(remoteRows, table: name)
                totalConflictsResolved += resolved.conflictsResolved

                if !resolved.rows.isEmpty {
                    try await self.sqliteService.upsert(table: name, rows: resolved.rows)
                }
            }
        )

        if totalConflictsResolved > 0 {
            let strategy = TableConflictMapping.strategy(for: name)
            Logger.info("[SyncEngine] Resolved \(totalConflictsResolved) conflicts in \(name) using \(strategy.rawValue) strategy")
        }

        Logger.debug("[SyncEngine] Pulled \(rowsPulled) rows from \(name)")
    }

    /// Applies conflict resolution to one page of remote rows.
    private func resolvePage(
        _ remoteRows: [[String: Any]],
        table name: String
    ) async -> (rows: [[String: Any]], conflictsResolved: Int) {
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

        return (resolvedRows, conflictsResolved)
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
        let record = Self.normalizedMutationRecord(
            table: operation.tableName,
            operationType: operation.operationType,
            recordId: operation.recordId,
            payload: operation.payload
        )

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

        // When this increment reaches the retry ceiling, mark the op 'stuck' so it leaves the
        // active pool explicitly instead of lingering as a high-`attempts` 'failed' row that
        // fetchPendingOperations silently skips forever (STAB-007). Launch-time recovery
        // (recoverStuckOperationsSQL) then gives it a fresh chance on a later run.
        let sql = """
            UPDATE sync_outbox
            SET attempts = attempts + 1,
                last_error = ?,
                next_retry_at = ?,
                status = CASE WHEN attempts + 1 >= ? THEN 'stuck' ELSE status END
            WHERE operation_id = ?
        """
        let success = sqliteService.execute(sql, parameters: [error, nextRetryString, maxRetries, operationId])
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
        _ = sqliteService.execute(Self.recoverRetryableListItemOperationsSQL(maxRetries: maxRetries))
    }

    /// Resets all PGRST205-blocked outbox operations to `pending` so they will be retried
    /// on this launch's sync push. Called once at app launch before pushPendingChanges().
    public func unblockAndRetryBlockedOperations() {
        unblockSchemaErrorOperations()
        // Once per launch (not per push, so in-session backoff is preserved): give retry-exhausted
        // ops of every table a fresh chance. STAB-007.
        _ = sqliteService.execute(Self.recoverStuckOperationsSQL(maxRetries: maxRetries))
        Logger.info("[SyncEngine] Unblocked PGRST205-blocked and retry-exhausted operations for retry on launch")
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

    /// Get the state machine's history for debugging
    public func getStateHistory() -> [SyncStateHistoryEntry] {
        return stateMachine.getHistory()
    }

    /// Get a debug description of the current sync state
    public func getStateDebugInfo() -> String {
        var info: [String] = []
        info.append("Current State: \(stateMachine.currentState)")
        info.append("Is Syncing: \(isSyncing)")
        info.append("Is Online: \(isOnline)")
        info.append("Pending Operations: \(pendingOperationsCount)")
        if let lastSync = lastSyncAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            info.append("Last Sync: \(formatter.string(from: lastSync))")
        }
        if let error = lastError {
            info.append("Last Error: \(error)")
        }
        info.append("")
        info.append("State History:")
        info.append(stateMachine.historyDescription())
        return info.joined(separator: "\n")
    }

    /// Force transition to a specific state (for testing/debugging only)
    @discardableResult
    public func forceState(_ state: SyncState, reason: String? = nil) -> Bool {
        Logger.warning("[SyncEngine] Forcing state transition to \(state.logDescription)")
        return stateMachine.transition(to: state, reason: reason ?? "Forced state change")
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
