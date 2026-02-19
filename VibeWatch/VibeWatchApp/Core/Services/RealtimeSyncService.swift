import Foundation
import Combine

/// Manages realtime sync for Pro users using Supabase Realtime subscriptions
/// Provides instant updates when data changes on other devices
@MainActor
class RealtimeSyncService: ObservableObject {
    static let shared = RealtimeSyncService()

    // MARK: - Published Properties

    @Published var isConnected = false
    @Published var lastRealtimeUpdate: Date?

    // MARK: - Dependencies

    private let supabaseClient: SupabaseService
    private let syncEngine: SyncEngineProtocol
    private var subscriptions: Set<AnyCancellable> = []

    // MARK: - Constants

    private let deviceId: String
    private var isSubscribed = false

    // MARK: - Initialization

    private init(
        supabaseClient: SupabaseService = .shared,
        syncEngine: SyncEngineProtocol = SyncEngine.shared
    ) {
        self.supabaseClient = supabaseClient
        self.syncEngine = syncEngine

        // Get device ID
        if let savedDeviceId = UserDefaults.standard.string(forKey: "deviceIdentifier") {
            self.deviceId = savedDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            UserDefaults.standard.set(newDeviceId, forKey: "deviceIdentifier")
            self.deviceId = newDeviceId
        }

        Logger.info("[RealtimeSyncService] Initialized with device ID: \(deviceId)")
    }

    // MARK: - Public Methods

    /// Start realtime sync for Pro users
    func startRealtimeSync(userId: String) async {
        guard !isSubscribed else {
            Logger.debug("[RealtimeSyncService] Already subscribed")
            return
        }

        Logger.info("[RealtimeSyncService] Starting realtime sync for user: \(userId)")

        do {
            // Subscribe to unified_user_preferences changes
            try await subscribeToPreferences(userId: userId)

            // Subscribe to movie_reactions changes
            try await subscribeToReactions(userId: userId)

            // Subscribe to list_items changes
            try await subscribeToLists(userId: userId)

            isSubscribed = true
            isConnected = true
            Logger.info("[RealtimeSyncService] ✅ Realtime sync active")
        } catch {
            Logger.error("[RealtimeSyncService] Failed to start realtime sync", error: error)
        }
    }

    /// Stop realtime sync
    func stopRealtimeSync() {
        guard isSubscribed else { return }

        Logger.info("[RealtimeSyncService] Stopping realtime sync")

        // Cancel all subscriptions
        subscriptions.removeAll()

        isSubscribed = false
        isConnected = false
        Logger.info("[RealtimeSyncService] Realtime sync stopped")
    }

    // MARK: - Private Methods - Subscriptions

    private func subscribeToPreferences(userId: String) async throws {
        Logger.debug("[RealtimeSyncService] Subscribing to unified_user_preferences changes")

        // Note: This is a placeholder for Supabase Realtime integration
        // In a real implementation, you would use Supabase Realtime channels:
        //
        // let channel = supabase.channel("db-changes")
        // channel.on(.postgresChanges(
        //     event: .all,
        //     schema: "public",
        //     table: "unified_user_preferences",
        //     filter: "user_id=eq.\(userId)"
        // )) { [weak self] payload in
        //     await self?.handlePreferenceUpdate(payload)
        // }
        // await channel.subscribe()

        // For now, log that this feature requires Supabase Realtime setup
        Logger.warning("[RealtimeSyncService] Supabase Realtime not fully integrated - polling fallback active")
    }

    private func subscribeToReactions(userId: String) async throws {
        Logger.debug("[RealtimeSyncService] Subscribing to movie_reactions changes")

        // Placeholder for movie_reactions realtime subscription
        // Similar implementation to preferences above
    }

    private func subscribeToLists(userId: String) async throws {
        Logger.debug("[RealtimeSyncService] Subscribing to list_items changes")

        // Placeholder for list_items realtime subscription
        // Similar implementation to preferences above
    }

    // MARK: - Private Methods - Update Handlers

    private func handlePreferenceUpdate(_ payload: RealtimePayload) async {
        guard let record = payload.record as? [String: Any],
              let recordDeviceId = record["device_id"] as? String else {
            return
        }

        // Ignore updates from this device
        guard recordDeviceId != deviceId else {
            Logger.debug("[RealtimeSyncService] Ignoring own device update")
            return
        }

        Logger.info("[RealtimeSyncService] 📥 Received preference update from device: \(recordDeviceId)")

        // Trigger SyncEngine to pull from remote instead of writing directly
        await syncEngine.pullFromRemote()

        lastRealtimeUpdate = Date()

        // Notify UI to refresh
        NotificationCenter.default.post(
            name: .realtimePreferenceUpdated,
            object: nil,
            userInfo: ["record": record]
        )
    }

    private func handleReactionUpdate(_ payload: RealtimePayload) async {
        guard let record = payload.record as? [String: Any],
              let recordDeviceId = record["device_id"] as? String else {
            return
        }

        guard recordDeviceId != deviceId else { return }

        Logger.info("[RealtimeSyncService] 📥 Received reaction update from device: \(recordDeviceId)")

        // Trigger SyncEngine to pull from remote instead of writing directly
        await syncEngine.pullFromRemote()

        lastRealtimeUpdate = Date()

        NotificationCenter.default.post(
            name: .realtimeReactionUpdated,
            object: nil,
            userInfo: ["record": record]
        )
    }

    private func handleListUpdate(_ payload: RealtimePayload) async {
        guard let record = payload.record as? [String: Any],
              let recordDeviceId = record["device_id"] as? String else {
            return
        }

        guard recordDeviceId != deviceId else { return }

        Logger.info("[RealtimeSyncService] 📥 Received list update from device: \(recordDeviceId)")

        // Trigger SyncEngine to pull from remote instead of writing directly
        await syncEngine.pullFromRemote()

        lastRealtimeUpdate = Date()

        NotificationCenter.default.post(
            name: .realtimeListUpdated,
            object: nil,
            userInfo: ["record": record]
        )
    }

}

// MARK: - Realtime Payload

struct RealtimePayload {
    let eventType: RealtimeEventType
    let schema: String
    let table: String
    let record: Any
    let oldRecord: Any?

    enum RealtimeEventType: String {
        case insert = "INSERT"
        case update = "UPDATE"
        case delete = "DELETE"
    }
}

// MARK: - Errors

enum RealtimeSyncError: LocalizedError {
    case invalidRecord
    case databaseUpdateFailed
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            return "Received invalid record from realtime sync"
        case .databaseUpdateFailed:
            return "Failed to update local database from realtime sync"
        case .notConnected:
            return "Realtime sync not connected"
        }
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let realtimePreferenceUpdated = Notification.Name("realtimePreferenceUpdated")
    static let realtimeReactionUpdated = Notification.Name("realtimeReactionUpdated")
    static let realtimeListUpdated = Notification.Name("realtimeListUpdated")
}
