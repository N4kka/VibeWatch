import Foundation
import SwiftUI

/// Syncs pending operations from local SQLite to remote Supabase
/// Implements offline-first architecture with eventual consistency
@MainActor
class SyncWorker: ObservableObject {
    static let shared = SyncWorker()
    
    // MARK: - Published State
    
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var pendingCount = 0
    @Published var stuckCount = 0
    @Published var lastError: String?
    @Published var isOnline = false
    
    // MARK: - Dependencies
    
    private let localDB = SQLiteService.shared
    private let remoteDB = SupabaseService.shared
    
    // MARK: - Configuration
    
    private let batchSize = 50
    private let syncInterval: TimeInterval = 60 // run push loop every 60s
    private let maxAttempts = 5
    private let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16] // seconds
    private let cooldownInterval: TimeInterval = 600 // 10 minutes between cycles after max attempts
    private let userPullThrottle: TimeInterval = 20 * 60 // 20 minutes between user pulls
    private let contentPullThrottle: TimeInterval = 24 * 60 * 60 // 24h between content pulls
    
    private var syncTimer: Timer?
    private var lastUserPull: Date?
    private var lastContentPull: Date?
    
    // MARK: - Initialization
    
    private init() {
        Task {
            await startPeriodicSync()
        }
        
        // Listen for app lifecycle events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillBackground),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }
    
    // MARK: - Public API
    
    /// Start automatic periodic syncing
    func startPeriodicSync() async {
        stopPeriodicSync()
        
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.syncIfNeeded()
            }
        }
        
        Logger.info("[SyncWorker] Periodic sync started (every \(syncInterval)s)")
        
        // Initial sync
        await syncIfNeeded()
        await performPullsIfDue()
    }
    
    /// Stop automatic syncing
    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    /// Force sync now (manual trigger)
    func forceSyncNow() async {
        Logger.info("[SyncWorker] Force sync triggered")
        await performSync()
        await performPullsIfDue(forceUserPull: true, forceContentPull: false)
    }
    
    // MARK: - Queue Management
    
    /// Add operation to sync queue
    func queueOperation(
        userId: String,
        tableName: String,
        operationType: String,
        recordId: String,
        payload: [String: Any],
        dependsOn: Int? = nil
    ) async throws {
        let operationId = UUID().uuidString
        
        // Convert payload to JSON string
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
        
        var values: [String: Any] = [
            "operation_id": operationId,
            "user_id": userId,
            "table_name": tableName,
            "operation_type": operationType,
            "record_id": recordId,
            "payload": payloadString,
            "status": "pending"
        ]
        
        if let dependsOn = dependsOn {
            values["depends_on_id"] = dependsOn
        }
        
        _ = try await localDB.insert("sync_outbox", values: values)
        
        // Update pending count
        await updateCounts()
        
        Logger.info("[SyncWorker] Queued \(operationType) on \(tableName) for \(recordId)")
        
        // Trigger sync if batch size reached
        if pendingCount >= batchSize {
            Task {
                await syncIfNeeded()
            }
        }
    }
    
    /// Get pending operations count
    func getPendingCount() async -> Int {
        do {
            return try await localDB.count(
                "sync_outbox",
                where: "status IN ('pending', 'failed')"
            )
        } catch {
            Logger.warning("[SyncWorker] Failed to get pending count: \(error.localizedDescription)")
            return 0
        }
    }
    
    /// Get stuck operations count
    func getStuckCount() async -> Int {
        do {
            return try await localDB.count(
                "sync_outbox",
                where: "status = 'stuck'"
            )
        } catch {
            Logger.warning("[SyncWorker] Failed to get stuck count: \(error.localizedDescription)")
            return 0
        }
    }
    
    /// Reset stuck operations (admin action)
    func resetStuckOperations() async {
        do {
            _ = try await localDB.queryRaw("""
                UPDATE sync_outbox
                SET status = 'pending',
                    attempts = 0,
                    next_retry_at = NULL,
                    last_error = NULL
                WHERE status = 'stuck'
            """)
            
            await updateCounts()
            Logger.info("[SyncWorker] Reset all stuck operations")
            
        } catch {
            Logger.error("[SyncWorker] Failed to reset stuck operations", error: error)
        }
    }
    
    /// View pending operations (for debugging)
    func getPendingOperations() async -> [[String: Any]] {
        do {
            let rows = try await localDB.queryRaw("""
                SELECT id, table_name, operation_type, record_id, attempts, last_error
                FROM sync_outbox
                WHERE status IN ('pending', 'failed', 'stuck')
                ORDER BY created_at DESC
                LIMIT 50
            """)
            return rows
        } catch {
            Logger.warning("[SyncWorker] Failed to get pending operations: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Core Sync Logic
    
    private func syncIfNeeded() async {
        guard !isSyncing else {
            return
        }
        
        // Update counts
        await updateCounts()
        
        guard pendingCount > 0 else {
            return
        }
        
        // Check if remote is healthy
        guard await checkRemoteHealth() else {
            isOnline = false
            return
        }
        
        isOnline = true
        await performSync()
        await performPullsIfDue()
    }
    
    private func performSync() async {
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            // Fetch pending operations
            let operations = try await fetchPendingOperations(limit: batchSize)
            
            guard !operations.isEmpty else {
                return
            }
            
            Logger.info("[SyncWorker] Syncing \(operations.count) operations...")
            
            // Group by user_id for transactional integrity
            let grouped = Dictionary(grouping: operations, by: { $0.userId })
            
            var successCount = 0
            var failCount = 0
            
            for (userId, userOps) in grouped {
                do {
                    try await syncUserBatch(userId: userId, operations: userOps)
                    successCount += userOps.count
                    Logger.info("[SyncWorker] Synced \(userOps.count) operations for user \(userId)")
                } catch {
                    failCount += userOps.count
                    Logger.error("[SyncWorker] Failed to sync user \(userId)", error: error)
                    await handleBatchFailure(operations: userOps, error: error)
                }
            }
            
            lastSyncDate = Date()
            await updateCounts()
            
            Logger.info("[SyncWorker] Sync complete: \(successCount) success, \(failCount) failed")
            
        } catch {
            lastError = error.localizedDescription
            Logger.error("[SyncWorker] Sync failed", error: error)
        }
    }
    
    private func syncUserBatch(userId: String, operations: [SyncOperation]) async throws {
        // Mark all as in_progress
        let ids = operations.map { String($0.id) }.joined(separator: ",")
        _ = try await localDB.queryRaw("""
            UPDATE sync_outbox
            SET status = 'in_progress'
            WHERE id IN (\(ids))
        """)
        
        do {
            // Execute all operations
            try await executeRemoteOperations(operations: operations)
            
            // Mark all as completed
            _ = try await localDB.queryRaw("""
                UPDATE sync_outbox
                SET status = 'completed',
                    synced_at = datetime('now')
                WHERE id IN (\(ids))
            """)
            
            // Log success
            await logSyncBatch(operations: operations, success: true)
            
        } catch {
            // Revert to pending/failed
            _ = try? await localDB.queryRaw("""
                UPDATE sync_outbox
                SET status = 'pending'
                WHERE id IN (\(ids))
            """)
            throw error
        }
    }
    
    private func executeRemoteOperations(operations: [SyncOperation]) async throws {
        // Verify Supabase is configured
        guard remoteDB.client != nil else {
            throw SyncError.remoteUnavailable
        }

        // Build batch payload for RPC
        var batch: [[String: Any]] = []
        for op in operations {
            var record = op.payload
            // ensure id present in record
            if record["id"] == nil {
                record["id"] = op.recordId
            }
            // sanitize media_type
            if op.tableName == "clips" || op.tableName == "list_items" {
                if let mt = record["media_type"] as? String, !["movie", "tv"].contains(mt) {
                    record["media_type"] = "movie"
                }
            }
            let entry: [String: Any] = [
                "op": op.operationType.uppercased(),
                "table": op.tableName,
                "id": op.recordId,
                "record": record
            ]
            batch.append(entry)
        }

        // Call server-side RPC to apply atomically
        try await remoteDB.applyMutations(batch)
    }
    
    // MARK: - Health Checks
    
    private func checkRemoteHealth() async -> Bool {
        guard let client = remoteDB.client else {
            return false
        }
        
        do {
            // Simple ping query
            _ = try await client
                .from("clips")
                .select("id")
                .limit(1)
                .execute()
            
            return true
            
        } catch {
            Logger.warning("[SyncWorker] Health check failed: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Error Handling & Retry
    
    private func handleBatchFailure(operations: [SyncOperation], error: Error) async {
        for op in operations {
            let newAttempts = op.attempts + 1
            
            let errorMsg = error.localizedDescription.replacingOccurrences(of: "'", with: "''")
            
            // If we've hit the max attempts for this cycle, schedule a cooldown and reset attempts.
            if newAttempts >= maxAttempts {
                let nextRetry = Date().addingTimeInterval(cooldownInterval)
                let formatter = ISO8601DateFormatter()
                let nextRetryStr = formatter.string(from: nextRetry)
                
                _ = try? await localDB.queryRaw("""
                    UPDATE sync_outbox
                    SET status = 'failed',
                        attempts = 0,
                        next_retry_at = '\(nextRetryStr)',
                        last_error = '\(errorMsg)'
                    WHERE id = \(op.id)
                """)
                
                Logger.warning("[SyncWorker] Operation \(op.id) reached max attempts. Cooling down until \(nextRetryStr)")
            } else {
                let nextRetry = calculateNextRetry(attempts: newAttempts)
                let formatter = ISO8601DateFormatter()
                let nextRetryStr = formatter.string(from: nextRetry)
                
                _ = try? await localDB.queryRaw("""
                    UPDATE sync_outbox
                    SET status = 'failed',
                        attempts = \(newAttempts),
                        next_retry_at = '\(nextRetryStr)',
                        last_error = '\(errorMsg)'
                    WHERE id = \(op.id)
                """)
                
                Logger.debug("[SyncWorker] Will retry operation \(op.id) at \(nextRetryStr)")
            }
        }
    }
    
    private func calculateNextRetry(attempts: Int) -> Date {
        let index = max(0, min(attempts - 1, backoffSchedule.count - 1))
        let delay = backoffSchedule[index]
        return Date().addingTimeInterval(delay)
    }
    
    // MARK: - Data Fetching
    
    private func fetchPendingOperations(limit: Int) async throws -> [SyncOperation] {
        let rows = try await localDB.queryRaw("""
            SELECT * FROM sync_outbox
            WHERE status IN ('pending', 'failed')
              AND (next_retry_at IS NULL OR next_retry_at <= datetime('now'))
              AND (depends_on_id IS NULL 
                   OR depends_on_id IN (
                     SELECT id FROM sync_outbox WHERE status = 'completed'
                   ))
            ORDER BY id ASC
            LIMIT \(limit)
        """)
        
        return rows.compactMap { SyncOperation(row: $0) }
    }
    
    private func updateCounts() async {
        pendingCount = await getPendingCount()
        stuckCount = await getStuckCount()
    }
    
    // MARK: - Logging
    
    private func logSyncBatch(operations: [SyncOperation], success: Bool) async {
        let batchId = UUID().uuidString
        
        for op in operations {
            let values: [String: Any] = [
                "sync_batch_id": batchId,
                "operation_id": op.operationId,
                "user_id": op.userId,
                "table_name": op.tableName,
                "operation_type": op.operationType,
                "status": success ? "success" : "failed",
                "error_message": lastError ?? ""
            ]
            
            _ = try? await localDB.insert("sync_log", values: values)
        }
    }

    // MARK: - Pull Logic (server -> local)

    private func performPullsIfDue(forceUserPull: Bool = false, forceContentPull: Bool = false) async {
        let now = Date()

        let shouldPullUser = forceUserPull || lastUserPull == nil || now.timeIntervalSince(lastUserPull ?? .distantPast) >= userPullThrottle
        let shouldPullContent = forceContentPull || lastContentPull == nil || now.timeIntervalSince(lastContentPull ?? .distantPast) >= contentPullThrottle

        if shouldPullUser {
            await pullUserScopedData()
            lastUserPull = Date()
        }

        if shouldPullContent {
            await pullContentData()
            lastContentPull = Date()
        }
    }

    /// Pull user-scoped tables filtered by current user_id
    private func pullUserScopedData() async {
        guard let userId = remoteDB.currentUser?.id else { return }
        Logger.info("[SyncWorker] Pulling user-scoped data for \(userId)")

        do {
            // Profiles
            try await remoteDB.pullTable(name: "profiles", userId: userId)
            // Preferences
            try await remoteDB.pullTable(name: "user_preferences", userId: userId)
            // Quota + AI usage + history
            try await remoteDB.pullTable(name: "user_daily_quota", userId: userId)
            try await remoteDB.pullTable(name: "user_ai_token_usage", userId: userId)
            try await remoteDB.pullTable(name: "user_clip_history", userId: userId)
            // Lists + items
            try await remoteDB.pullTable(name: "lists", userId: userId)
            try await remoteDB.pullTable(name: "list_items", userId: userId)
            // Notifications
            try await remoteDB.pullTable(name: "notifications", userId: userId)
            // Devices
            try await remoteDB.pullTable(name: "user_devices", userId: userId)

            Logger.info("[SyncWorker] User pull complete")
        } catch {
            Logger.error("[SyncWorker] User pull failed", error: error)
        }
    }

    /// Pull content tables (one-way server -> local)
    private func pullContentData() async {
        Logger.info("[SyncWorker] Pulling content data (clips/discovery/trailers/media caches)")
        do {
            try await remoteDB.pullTable(name: "clips", userId: nil)
            try await remoteDB.pullTable(name: "discovery_cache", userId: nil)
            try await remoteDB.pullTable(name: "trailers_cache", userId: nil)
            try await remoteDB.pullTable(name: "media_details_cache", userId: nil)
            try await remoteDB.pullTable(name: "media_availability", userId: nil)
            Logger.info("[SyncWorker] Content pull complete")
        } catch {
            Logger.error("[SyncWorker] Content pull failed", error: error)
        }
    }
    
    // MARK: - App Lifecycle
    
    @objc private func appWillBackground() {
        Task {
            Logger.info("[SyncWorker] App backgrounding - forcing sync...")
            await forceSyncNow()
        }
    }
}

// MARK: - Models


// Note: SyncOperation and SyncError are defined in separate files:
// - Core/Database/SyncOperation.swift
// - Core/Database/SyncError.swift
