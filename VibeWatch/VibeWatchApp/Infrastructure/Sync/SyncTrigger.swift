import Foundation

/// Represents the reason why a sync operation was triggered.
/// Used to determine sync behavior and prioritization.
public enum SyncTrigger: String, Sendable, Equatable {
    /// App just launched - always perform full sync
    case appLaunch

    /// App returned to foreground after being in background > 2 minutes
    case foregroundResume

    /// User performed an action that should sync immediately (e.g., save, react)
    case userAction

    /// Periodic sync timer fired (every 60 seconds when app is active)
    case periodic

    /// Network connectivity was restored after being offline
    case networkRestored

    /// User manually triggered a refresh (e.g., pull-to-refresh)
    case manualRefresh

    /// Realtime event received via WebSocket
    case realtimeEvent

    // MARK: - Sync Behavior Configuration

    /// Whether this trigger should perform a full bidirectional sync
    var shouldPerformFullSync: Bool {
        switch self {
        case .appLaunch, .foregroundResume, .networkRestored, .manualRefresh:
            return true
        case .userAction, .periodic, .realtimeEvent:
            return false
        }
    }

    /// Whether this trigger should attempt to push pending changes
    var shouldPushChanges: Bool {
        // All triggers should push pending changes
        return true
    }

    /// Whether this trigger should pull remote changes
    var shouldPullChanges: Bool {
        switch self {
        case .appLaunch, .foregroundResume, .networkRestored, .manualRefresh, .realtimeEvent:
            return true
        case .userAction, .periodic:
            return false
        }
    }

    /// Priority level for this trigger (higher = more urgent)
    var priority: Int {
        switch self {
        case .userAction:
            return 100  // Highest - user is waiting
        case .manualRefresh:
            return 90   // User explicitly requested
        case .appLaunch:
            return 80   // App startup experience
        case .foregroundResume:
            return 70   // User returning to app
        case .networkRestored:
            return 60   // Important to sync accumulated changes
        case .realtimeEvent:
            return 50   // External update
        case .periodic:
            return 10   // Background maintenance
        }
    }

    /// Human-readable description for logging
    var logDescription: String {
        switch self {
        case .appLaunch:
            return "App Launch"
        case .foregroundResume:
            return "Foreground Resume"
        case .userAction:
            return "User Action"
        case .periodic:
            return "Periodic Timer"
        case .networkRestored:
            return "Network Restored"
        case .manualRefresh:
            return "Manual Refresh"
        case .realtimeEvent:
            return "Realtime Event"
        }
    }
}
