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
    private let syncInterval: TimeInterval = 30
    private let maxAttempts = 5
    
    private var syncTimer: Timer?
    
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
        
        print("🔄 [SyncWorker] Periodic sync started (every \(syncInterval)s)")
        
        // Initial sync
        await syncIfNeeded()
    }
    
    /// Stop automatic syncing
    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    /// Force sync now (manual trigger)
    func forceSyncNow() async {
        print("🔄 [SyncWorker] Force sync triggered")
        await performSync()
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
        
        print("➕ [SyncWorker] Queued \(operationType) on \(tableName) for \(recordId)")
        
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
            print("⚠️ [SyncWorker] Failed to get pending count: \(error)")
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
            print("⚠️ [SyncWorker] Failed to get stuck count: \(error)")
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
            print("✅ [SyncWorker] Reset all stuck operations")
            
        } catch {
            print("❌ [SyncWorker] Failed to reset stuck operations: \(error)")
        }
    }
    
    /// View pending operations (for debugging)
    func getPendingOperations() async -> [[String: Any]] {
        do {
            return try await localDB.queryRaw("""
                SELECT id, table_name, operation_type, record_id, attempts, last_error
                FROM sync_outbox
                WHERE status IN ('pending', 'failed', 'stuck')
                ORDER BY created_at DESC
                LIMIT 50
            """)
        } catch {
            print("⚠️ [SyncWorker] Failed to get pending operations: \(error)")
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
            
            print("🔄 [SyncWorker] Syncing \(operations.count) operations...")
            
            // Group by user_id for transactional integrity
            let grouped = Dictionary(grouping: operations, by: { $0.userId })
            
            var successCount = 0
            var failCount = 0
            
            for (userId, userOps) in grouped {
                do {
                    try await syncUserBatch(userId: userId, operations: userOps)
                    successCount += userOps.count
                    print("✅ [SyncWorker] Synced \(userOps.count) operations for user \(userId)")
                } catch {
                    failCount += userOps.count
                    print("❌ [SyncWorker] Failed to sync user \(userId): \(error)")
                    await handleBatchFailure(operations: userOps, error: error)
                }
            }
            
            lastSyncDate = Date()
            await updateCounts()
            
            print("✅ [SyncWorker] Sync complete: \(successCount) success, \(failCount) failed")
            
        } catch {
            lastError = error.localizedDescription
            print("❌ [SyncWorker] Sync failed: \(error)")
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
        
        // Execute each operation
        for op in operations {
            do {
                switch op.operationType {
                case "INSERT", "UPDATE":
                    // Convert payload dictionary to JSON string for raw HTTP request
                    let payloadData = try JSONSerialization.data(withJSONObject: op.payload)
                    
                    // Perform HTTP request directly to Supabase REST API
                    guard let supabaseURL = URL(string: Config.supabaseURL) else {
                        throw SyncError.invalidPayload
                    }
                    
                    let url = supabaseURL
                        .appendingPathComponent("rest")
                        .appendingPathComponent("v1")
                        .appendingPathComponent(op.tableName)
                    
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
                    request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
                    request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
                    request.httpBody = payloadData
                    
                    let (_, response) = try await URLSession.shared.data(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        throw SyncError.remoteUnavailable
                    }
                    
                case "DELETE":
                    // Soft delete (update deleted_at)
                    let now = ISO8601DateFormatter().string(from: Date())
                    let updatePayload: [String: String] = ["deleted_at": now]
                    let updateData = try JSONSerialization.data(withJSONObject: updatePayload)
                    
                    guard let supabaseURL = URL(string: Config.supabaseURL) else {
                        throw SyncError.invalidPayload
                    }
                    
                    let url = supabaseURL
                        .appendingPathComponent("rest")
                        .appendingPathComponent("v1")
                        .appendingPathComponent(op.tableName)
                    
                    var request = URLRequest(url: url)
                    request.httpMethod = "PATCH"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
                    request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("id=eq.\(op.recordId)", forHTTPHeaderField: "Prefer")
                    request.httpBody = updateData
                    
                    let (_, response) = try await URLSession.shared.data(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        throw SyncError.remoteUnavailable
                    }
                    
                default:
                    throw SyncError.unknownOperation(op.operationType)
                }
                
                print("  ✓ Synced \(op.operationType) on \(op.tableName)")
                
            } catch {
                print("  ✗ Failed \(op.operationType) on \(op.tableName): \(error)")
                throw error
            }
        }
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
            print("⚠️ [SyncWorker] Health check failed: \(error)")
            return false
        }
    }
    
    // MARK: - Error Handling & Retry
    
    private func handleBatchFailure(operations: [SyncOperation], error: Error) async {
        for op in operations {
            let newAttempts = op.attempts + 1
            
            let errorMsg = error.localizedDescription.replacingOccurrences(of: "'", with: "''")
            
            if newAttempts >= maxAttempts {
                // Mark as stuck
                _ = try? await localDB.queryRaw("""
                    UPDATE sync_outbox
                    SET status = 'stuck',
                        attempts = \(newAttempts),
                        last_error = '\(errorMsg)'
                    WHERE id = \(op.id)
                """)
                
                print("⚠️ [SyncWorker] Operation \(op.id) stuck after \(maxAttempts) attempts")
                
            } else {
                // Schedule retry
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
                
                print("🔄 [SyncWorker] Will retry operation \(op.id) at \(nextRetry)")
            }
        }
    }
    
    private func calculateNextRetry(attempts: Int) -> Date {
        let baseDelay: TimeInterval = 2.0
        let maxDelay: TimeInterval = 300.0 // 5 minutes
        let jitter: TimeInterval = 1.0
        
        // Exponential backoff: 2^attempts * baseDelay
        let delay = min(pow(2.0, Double(attempts)) * baseDelay, maxDelay)
        let jitterAmount = Double.random(in: 0...jitter)
        
        return Date().addingTimeInterval(delay + jitterAmount)
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
    
    // MARK: - App Lifecycle
    
    @objc private func appWillBackground() {
        Task {
            print("📱 [SyncWorker] App backgrounding - forcing sync...")
            await forceSyncNow()
        }
    }
}

// MARK: - Models

struct SyncOperation {
    let id: Int
    let operationId: String
    let userId: String
    let tableName: String
    let operationType: String
    let recordId: String
    let payload: [String: Any]
    let attempts: Int
    let status: String
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
            print("⚠️ Failed to parse sync operation row")
            return nil
        }
        
        self.id = id
        self.operationId = operationId
        self.userId = userId
        self.tableName = tableName
        self.operationType = operationType
        self.recordId = recordId
        self.payload = payload
        self.attempts = row["attempts"] as? Int ?? 0
        self.status = status
        
        // Parse next_retry_at if present
        if let retryString = row["next_retry_at"] as? String {
            let formatter = ISO8601DateFormatter()
            self.nextRetryAt = formatter.date(from: retryString)
        } else {
            self.nextRetryAt = nil
        }
    }
}

// MARK: - Error Types

enum SyncError: LocalizedError {
    case remoteUnavailable
    case unknownOperation(String)
    case invalidPayload
    
    var errorDescription: String? {
        switch self {
        case .remoteUnavailable:
            return "Remote database is unavailable"
        case .unknownOperation(let type):
            return "Unknown operation type: \(type)"
        case .invalidPayload:
            return "Invalid operation payload"
        }
    }
}
