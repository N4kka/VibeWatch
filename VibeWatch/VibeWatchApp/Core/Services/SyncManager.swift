import Foundation
import Combine

/// Manages bidirectional synchronization between local SQLite and Supabase
/// Implements outbox pattern for reliable offline-first sync with conflict resolution
@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()

    // MARK: - Published Properties

    @Published var isSyncing = false
    @Published var lastSyncAt: Date?
    @Published var pendingOperations: Int = 0
    @Published var lastError: String?

    // MARK: - Dependencies

    private let sqliteService: SQLiteService
    private let supabaseClient: SupabaseService
    private let networkMonitor: NetworkMonitor
    private var realtimeSync: RealtimeSyncService?

    // MARK: - Constants

    private let deviceId: String
    private let maxRetries = 5
    private let batchSize = 50

    // MARK: - Initialization

    private init(
        sqliteService: SQLiteService = .shared,
        supabaseClient: SupabaseService = .shared,
        networkMonitor: NetworkMonitor = .shared
    ) {
        self.sqliteService = sqliteService
        self.supabaseClient = supabaseClient
        self.networkMonitor = networkMonitor

        // Get or create device ID
        if let savedDeviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") {
            self.deviceId = savedDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            UserDefaults.standard.set(newDeviceId, forKey: "deviceIdentifier")
            self.deviceId = newDeviceId
        }

        // Load last sync time
        if let lastSync = UserDefaults.standard.object(forKey: "lastSyncTimestamp") as? Date {
            self.lastSyncAt = lastSync
        }

        Logger.info("[SyncManager] Initialized with device ID: \(deviceId)")

        // Start monitoring network and process pending operations
        startAutomaticSync()
    }

    // MARK: - Public Methods

    /// Queue a sync operation for reliable upload
    func queueSync(operation: SyncAction) async {
        do {
            let operationId = UUID().uuidString
            let now = ISO8601DateFormatter().string(from: Date())

            let payload: [String: Any]
            switch operation {
            case .updatePreferences(let signals):
                payload = [
                    "signals": signals.map { signal in
                        [
                            "category": signal.category,
                            "id": signal.id,
                            "name": signal.name,
                            "weight": signal.weight,
                            "source": signal.source.rawValue
                        ]
                    }
                ]
            case .addToList(let mediaId, let mediaType, let listId):
                payload = [
                    "media_id": mediaId,
                    "media_type": mediaType.rawValue,
                    "list_id": listId
                ]
            case .recordReaction(let mediaId, let mediaType, let reactionType):
                payload = [
                    "media_id": mediaId,
                    "media_type": mediaType.rawValue,
                    "reaction_type": reactionType
                ]
            case .logClipView(let clipId, let engagementData):
                payload = [
                    "clip_id": clipId,
                    "engagement": engagementData
                ]
            case .insertRecord(_, _, let record):
                payload = record
            case .upsertRecord(_, _, let record):
                payload = record
            }

            let payloadJSON = try JSONSerialization.data(withJSONObject: payload)
            let payloadString = String(data: payloadJSON, encoding: .utf8) ?? "{}"

            let sql = """
                INSERT INTO sync_outbox (
                    operation_id, user_id, table_name, operation_type,
                    record_id, payload, status, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
            """

            let userId = AuthService.shared.currentUser?.id ?? "anonymous"
            let tableName = operation.tableName
            let opType = operation.operationType
            let recordId = operation.recordId

            let success = sqliteService.execute(sql, parameters: [
                operationId, userId, tableName, opType, recordId, payloadString, now
            ])

            if success {
                await updatePendingCount()
                Logger.debug("[SyncManager] Queued operation: \(opType) on \(tableName)")

                // Attempt immediate sync if online
                if networkMonitor.isConnected {
                    await processSyncOutbox()
                }
            } else {
                Logger.error("[SyncManager] Failed to queue sync operation")
            }
        } catch {
            Logger.error("[SyncManager] Error queuing sync", error: error)
        }
    }

    /// Process pending sync operations from outbox
    func processSyncOutbox() async {
        guard !isSyncing else {
            Logger.debug("[SyncManager] Sync already in progress, skipping")
            return
        }

        guard networkMonitor.isConnected else {
            Logger.debug("[SyncManager] Offline, skipping sync")
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            // If a previous run was blocked due to missing Supabase tables, retry now.
            // Once migrations are deployed, these will start succeeding.
            unblockSchemaMissingOperations()

            // Get pending operations ordered by creation time
            let sql = """
                SELECT * FROM sync_outbox
                WHERE status = 'pending' AND attempts < ?
                ORDER BY created_at ASC
                LIMIT ?
            """

            let rows = try await sqliteService.queryRaw(sql, parameters: [maxRetries, batchSize])

            guard !rows.isEmpty else {
                Logger.debug("[SyncManager] No pending operations to sync")
                return
            }

            Logger.info("[SyncManager] Processing \(rows.count) pending operations")

            var successCount = 0
            var failureCount = 0

            for row in rows {
                guard let operationId = row["operation_id"] as? String,
                      let tableName = row["table_name"] as? String,
                      let operationType = row["operation_type"] as? String,
                      let recordId = row["record_id"] as? String,
                      let payloadString = row["payload"] as? String,
                      let payloadData = payloadString.data(using: .utf8) else {
                    continue
                }

                do {
                    // Execute sync operation
                    try await executeSyncOperation(
                        tableName: tableName,
                        operationType: operationType,
                        recordId: recordId,
                        payload: payloadData
                    )

                    // Mark as synced
                    try await markOperationSynced(operationId: operationId)
                    successCount += 1
                } catch {
                    let message = error.localizedDescription

                    // If the remote schema doesn't contain the table yet, retries will never succeed until migrations are deployed.
                    if isSchemaCacheMissingTableError(message) {
                        try? await markOperationBlocked(operationId: operationId, error: message)
                        Logger.warning("[SyncManager] Operation blocked (missing Supabase table): \(operationType) \(tableName) record=\(recordId) op=\(operationId) error=\(message)")
                        lastError = "Supabase schema missing table '\(tableName)'. Deploy migrations, then re-enable sync."
                        failureCount += 1
                        continue
                    }

                    // Increment retry count for transient failures
                    try await incrementRetryCount(operationId: operationId, error: message)
                    Logger.warning("[SyncManager] Operation failed: \(operationType) \(tableName) record=\(recordId) op=\(operationId) error=\(message)")
                    failureCount += 1
                }
            }

            Logger.info("[SyncManager] Sync complete: \(successCount) succeeded, \(failureCount) failed")

            // Update last sync time
            let now = Date()
            lastSyncAt = now
            UserDefaults.standard.set(now, forKey: "lastSyncTimestamp")

            await updatePendingCount()
        } catch {
            Logger.error("[SyncManager] Sync outbox processing failed", error: error)
            lastError = error.localizedDescription
        }
    }

    /// Download changes from Supabase and update local database
    func downloadChanges() async {
        guard networkMonitor.isConnected else {
            Logger.debug("[SyncManager] Offline, skipping download")
            return
        }

        guard let userId = AuthService.shared.currentUser?.id else {
            Logger.debug("[SyncManager] Not authenticated, skipping download")
            return
        }

        do {
            // Tables to sync
            let tables = [
                "profiles",
                "lists",
                "list_items",
                "user_preferences",
                "movie_reactions",
                "unified_user_preferences",
                "user_search_history",
                "user_discovery_interactions",
                "ai_conversation_history",
                "global_discovery_filters",
                "device_info"
            ]

            for table in tables {
                do {
                    try await supabaseClient.pullTable(name: table, userId: userId)
                    Logger.debug("[SyncManager] Downloaded \(table)")
                } catch {
                    Logger.warning("[SyncManager] Failed to download \(table): \(error.localizedDescription)")
                }
            }

            Logger.info("[SyncManager] Download complete")
        }
    }

    /// Full bidirectional sync
    func performFullSync() async {
        Logger.info("[SyncManager] Starting full bidirectional sync")
        await processSyncOutbox() // Upload first
        await downloadChanges() // Then download
        Logger.info("[SyncManager] Full sync complete")
    }

    /// Enable realtime sync for Pro users
    func enableRealtimeSync(userId: String, isPro: Bool) async {
        guard isPro else {
            Logger.info("[SyncManager] Realtime sync requires Pro subscription")
            return
        }

        if realtimeSync == nil {
            realtimeSync = RealtimeSyncService.shared
        }

        await realtimeSync?.startRealtimeSync(userId: userId)
    }

    /// Disable realtime sync
    func disableRealtimeSync() {
        realtimeSync?.stopRealtimeSync()
    }

    // MARK: - Private Methods

    private func executeSyncOperation(
        tableName: String,
        operationType: String,
        recordId: String,
        payload: Data
    ) async throws {
        let payloadDict = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]

        switch tableName {
        case "unified_user_preferences":
            try await syncPreferences(payload: payloadDict)
        case "list_items":
            try await syncListItem(operationType: operationType, payload: payloadDict)
        case "movie_reactions":
            try await syncReaction(payload: payloadDict)
        case "user_clip_history":
            try await syncClipHistory(payload: payloadDict)
        case "user_discovery_interactions",
             "user_search_history",
             "user_clip_signals",
             "ai_conversation_history",
             "global_discovery_filters",
             "device_info",
             "notification_subscriptions":
            try await syncGenericRecord(tableName: tableName, operationType: operationType, recordId: recordId, payload: payloadDict)
        // Gamification tables
        case "user_gamification":
            try await syncGamificationState(operationType: operationType, recordId: recordId, payload: payloadDict)
        case "xp_transactions":
            try await syncGenericRecord(tableName: tableName, operationType: operationType, recordId: recordId, payload: payloadDict)
        case "user_badges":
            try await syncGenericRecord(tableName: tableName, operationType: operationType, recordId: recordId, payload: payloadDict)
        case "user_daily_challenges":
            try await syncGenericRecord(tableName: tableName, operationType: operationType, recordId: recordId, payload: payloadDict)
        default:
            Logger.warning("[SyncManager] Unknown table for sync: \(tableName)")
        }
    }

    private func syncPreferences(payload: [String: Any]) async throws {
        guard let signals = payload["signals"] as? [[String: Any]] else {
            throw SyncManagerError.invalidPayload
        }

        guard let userId = AuthService.shared.currentUser?.id,
              let userUUID = UUID(uuidString: userId) else {
            throw SyncManagerError.notAuthenticated
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let preferences: [[String: Any]] = signals.map { signal in
            let source = (signal["source"] as? String) ?? ""
            let weight = (signal["weight"] as? Double) ?? 0.0

            var scores: [String: Any] = [
                "score_from_clips": 0.0,
                "score_from_discovery": 0.0,
                "score_from_search": 0.0,
                "score_from_ai": 0.0,
                "score_from_lists": 0.0
            ]

            switch source {
            case InteractionSource.clips.rawValue:
                scores["score_from_clips"] = weight
            case InteractionSource.discovery.rawValue:
                scores["score_from_discovery"] = weight
            case InteractionSource.search.rawValue:
                scores["score_from_search"] = weight
            case InteractionSource.ai.rawValue:
                scores["score_from_ai"] = weight
            case InteractionSource.lists.rawValue:
                scores["score_from_lists"] = weight
            default:
                break
            }

            return scores.merging([
                "device_id": deviceId,
                "preference_category": (signal["category"] as? String) ?? "",
                "preference_id": (signal["id"] as? String) ?? "",
                "preference_name": (signal["name"] as? String) ?? "",
                "score": weight,
                "interaction_count": 1,
                "last_interaction_at": now
            ]) { current, _ in current }
        }

        _ = try await supabaseClient.mergeUserPreferences(userId: userUUID, preferences: preferences)
    }

    private func syncListItem(operationType: String, payload: [String: Any]) async throws {
        let mutation: [String: Any] = [
            "op": operationType.uppercased(),
            "table": "list_items",
            "id": payload["id"] ?? "",
            "record": payload
        ]

        try await supabaseClient.applyMutations([mutation])
    }

    private func syncReaction(payload: [String: Any]) async throws {
        let mutation: [String: Any] = [
            "op": "UPSERT",
            "table": "movie_reactions",
            "id": payload["id"] ?? "",
            "record": payload
        ]

        try await supabaseClient.applyMutations([mutation])
    }

    private func syncClipHistory(payload: [String: Any]) async throws {
        let mutation: [String: Any] = [
            "op": "INSERT",
            "table": "user_clip_history",
            "id": payload["id"] ?? "",
            "record": payload
        ]

        try await supabaseClient.applyMutations([mutation])
    }

    /// Sync gamification state with user_id as the conflict key
    private func syncGamificationState(
        operationType: String,
        recordId: String,
        payload: [String: Any]
    ) async throws {
        // user_gamification uses user_id as the unique key
        try await supabaseClient.upsertRow(
            table: "user_gamification",
            onConflict: "user_id",
            record: payload
        )
    }

    private func syncGenericRecord(
        tableName: String,
        operationType: String,
        recordId: String,
        payload: [String: Any]
    ) async throws {
        let onConflict: String
        switch tableName {
        case "global_discovery_filters":
            onConflict = "user_id"
        case "device_info":
            onConflict = "device_id"
        default:
            onConflict = "id"
        }

        var record = payload
        if record["id"] == nil, onConflict == "id" {
            record["id"] = recordId
        }

        try await supabaseClient.upsertRow(table: tableName, onConflict: onConflict, record: record)
    }

    private func markOperationSynced(operationId: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
            UPDATE sync_outbox
            SET status = 'synced', synced_at = ?
            WHERE operation_id = ?
        """

        let success = sqliteService.execute(sql, parameters: [now, operationId])
        if !success {
            throw SyncManagerError.databaseError
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
            throw SyncManagerError.databaseError
        }
    }

    private func isSchemaCacheMissingTableError(_ error: String) -> Bool {
        // PostgREST error when a table isn't present in the schema cache.
        // Example: {"code":"PGRST205",...,"message":"Could not find the table 'public.user_search_history' in the schema cache"}
        error.contains("PGRST205") || error.localizedCaseInsensitiveContains("schema cache") && error.localizedCaseInsensitiveContains("Could not find the table")
    }

    private func unblockSchemaMissingOperations() {
        let sql = """
            UPDATE sync_outbox
            SET status = 'pending',
                attempts = 0,
                last_error = NULL
            WHERE status = 'blocked' AND last_error LIKE '%PGRST205%'
        """
        _ = sqliteService.execute(sql)
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
            throw SyncManagerError.databaseError
        }
    }

    private func getAttemptCount(operationId: String) async throws -> Int {
        let sql = "SELECT attempts FROM sync_outbox WHERE operation_id = ?"
        let rows = try await sqliteService.queryRaw(sql, parameters: [operationId])
        return rows.first?["attempts"] as? Int ?? 0
    }

    private func calculateNextRetryTime(attempts: Int) -> Date {
        // Exponential backoff: 1min, 5min, 15min, 1hr, 4hr
        let delays: [TimeInterval] = [60, 300, 900, 3600, 14400]
        let maxDelay: TimeInterval = 14400 // 4 hours
        let delay = attempts < delays.count ? delays[attempts] : maxDelay
        return Date().addingTimeInterval(delay)
    }

    private func updatePendingCount() async {
        do {
            let sql = "SELECT COUNT(*) as count FROM sync_outbox WHERE status = 'pending'"
            let rows = try await sqliteService.queryRaw(sql)
            pendingOperations = rows.first?["count"] as? Int ?? 0
        } catch {
            Logger.error("[SyncManager] Failed to update pending count", error: error)
        }
    }

    private func startAutomaticSync() {
        // Sync every 5 minutes when app is active and online
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.processSyncOutbox()
            }
        }

        // Sync when network becomes available
        NotificationCenter.default.addObserver(
            forName: .networkStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.processSyncOutbox()
            }
        }
    }

    // MARK: - Conflict Resolution

    /// Resolve conflict between local and remote records using data-specific strategies
    func resolveConflict<T: Syncable>(local: T, remote: T) -> T {
        // Use type-specific resolution strategies based on data type
        if let localPref = local as? UnifiedPreferenceRecord,
           let remotePref = remote as? UnifiedPreferenceRecord,
           let result = mergePreferences(local: localPref, remote: remotePref) as? T {
            return result
        }

        if let localList = local as? WatchlistItemRecord,
           let remoteList = remote as? WatchlistItemRecord,
           let result = unionMergeWatchlist(local: localList, remote: remoteList) as? T {
            return result
        }

        if let localReaction = local as? ReactionRecord,
           let remoteReaction = remote as? ReactionRecord,
           let result = lastWriteWins(local: localReaction, remote: remoteReaction) as? T {
            return result
        }

        // Default strategy: last-write-wins
        if let localDate = local.updatedAt, let remoteDate = remote.updatedAt {
            return localDate > remoteDate ? local : remote
        }
        return remote // If timestamps are missing, prefer remote
    }

    /// Merge preferences from multiple devices additively
    private func mergePreferences(local: UnifiedPreferenceRecord, remote: UnifiedPreferenceRecord) -> UnifiedPreferenceRecord {
        var merged = local

        // Additive merge: combine scores from both devices with time weighting
        // More recent device gets 60% weight, older gets 40%
        let localIsNewer = (local.updatedAt ?? Date.distantPast) > (remote.updatedAt ?? Date.distantPast)
        let localWeight: Double = localIsNewer ? 0.6 : 0.4
        let remoteWeight: Double = localIsNewer ? 0.4 : 0.6

        merged.score = (local.score * localWeight) + (remote.score * remoteWeight)
        merged.scoreFromClips = max(local.scoreFromClips, remote.scoreFromClips)
        merged.scoreFromDiscovery = max(local.scoreFromDiscovery, remote.scoreFromDiscovery)
        merged.scoreFromSearch = max(local.scoreFromSearch, remote.scoreFromSearch)
        merged.scoreFromAI = max(local.scoreFromAI, remote.scoreFromAI)
        merged.scoreFromLists = max(local.scoreFromLists, remote.scoreFromLists)
        merged.interactionCount = local.interactionCount + remote.interactionCount
        merged.updatedAt = Date()

        Logger.debug("[SyncManager] Merged preference \(local.preferenceId): local=\(local.score), remote=\(remote.score), merged=\(merged.score)")
        return merged
    }

    /// Union merge for watchlist items - keep both unless explicitly deleted
    private func unionMergeWatchlist(local: WatchlistItemRecord, remote: WatchlistItemRecord) -> WatchlistItemRecord {
        // If either is deleted, prefer the deletion
        if local.deletedAt != nil || remote.deletedAt != nil {
            let localDeleted = local.deletedAt ?? Date.distantFuture
            let remoteDeleted = remote.deletedAt ?? Date.distantFuture
            return localDeleted < remoteDeleted ? local : remote
        }

        // Otherwise, use most recent update
        return lastWriteWins(local: local, remote: remote)
    }

    /// Last-write-wins for reactions and other simple records
    private func lastWriteWins<T: Syncable>(local: T, remote: T) -> T {
        if let localDate = local.updatedAt, let remoteDate = remote.updatedAt {
            return localDate > remoteDate ? local : remote
        }
        return remote
    }
}

// MARK: - Syncable Records

/// Protocol for records that can be synced with conflict resolution
struct UnifiedPreferenceRecord: Syncable {
    let preferenceId: String
    var score: Double
    var scoreFromClips: Double
    var scoreFromDiscovery: Double
    var scoreFromSearch: Double
    var scoreFromAI: Double
    var scoreFromLists: Double
    var interactionCount: Int
    var updatedAt: Date?
    var deletedAt: Date?
}

struct WatchlistItemRecord: Syncable {
    let mediaId: Int
    var updatedAt: Date?
    var deletedAt: Date?
}

struct ReactionRecord: Syncable {
    let mediaId: Int
    var reactionType: String
    var updatedAt: Date?
    var deletedAt: Date?
}

// MARK: - Sync Operation

enum SyncAction {
    case updatePreferences([PreferenceSignal])
    case addToList(mediaId: Int, mediaType: MediaType, listId: String)
    case recordReaction(mediaId: Int, mediaType: MediaType, reactionType: String)
    case logClipView(clipId: String, engagementData: [String: Any])
    case insertRecord(table: String, recordId: String, record: [String: Any])
    case upsertRecord(table: String, recordId: String, record: [String: Any])

    var tableName: String {
        switch self {
        case .updatePreferences: return "unified_user_preferences"
        case .addToList: return "list_items"
        case .recordReaction: return "movie_reactions"
        case .logClipView: return "user_clip_history"
        case .insertRecord(let table, _, _): return table
        case .upsertRecord(let table, _, _): return table
        }
    }

    var operationType: String {
        switch self {
        case .updatePreferences: return "UPSERT"
        case .addToList: return "INSERT"
        case .recordReaction: return "UPSERT"
        case .logClipView: return "INSERT"
        case .insertRecord: return "INSERT"
        case .upsertRecord: return "UPSERT"
        }
    }

    var recordId: String {
        switch self {
        case .updatePreferences: return UUID().uuidString
        case .addToList(let mediaId, _, _): return String(mediaId)
        case .recordReaction(let mediaId, _, _): return String(mediaId)
        case .logClipView(let clipId, _): return clipId
        case .insertRecord(_, let recordId, _): return recordId
        case .upsertRecord(_, let recordId, _): return recordId
        }
    }
}

// MARK: - Syncable Protocol

protocol Syncable {
    var updatedAt: Date? { get }
}

// MARK: - Errors

enum SyncManagerError: LocalizedError {
    case invalidPayload
    case databaseError
    case networkError
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Invalid sync payload format"
        case .databaseError:
            return "Database operation failed during sync"
        case .networkError:
            return "Network error during sync"
        case .notAuthenticated:
            return "User must be authenticated to sync"
        }
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let networkStatusChanged = Notification.Name("networkStatusChanged")
    static let syncCompleted = Notification.Name("syncCompleted")
}
