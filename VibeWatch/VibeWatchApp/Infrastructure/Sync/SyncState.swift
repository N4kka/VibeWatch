import Foundation

// MARK: - SyncOperationType

/// Represents the type of sync operation currently in progress.
/// Used as an associated value in SyncState.syncing to provide operation context.
public enum SyncOperationType: Equatable, Sendable, CustomStringConvertible {
    /// Uploading local changes to the remote server
    case push

    /// Downloading remote changes to local database
    case pull

    /// Full bidirectional sync (push then pull)
    case fullSync

    // MARK: - CustomStringConvertible

    public var description: String {
        switch self {
        case .push:
            return "Push"
        case .pull:
            return "Pull"
        case .fullSync:
            return "Full Sync"
        }
    }

    /// Human-readable description for logging
    public var logDescription: String {
        switch self {
        case .push:
            return "pushing local changes"
        case .pull:
            return "pulling remote changes"
        case .fullSync:
            return "performing full sync"
        }
    }
}

// MARK: - SyncStateError

/// Errors specific to sync state that can be associated with the error state.
/// Extends the existing SyncEngineError with additional state-related context.
public enum SyncStateError: LocalizedError, Equatable, Sendable {
    /// Network request failed
    case networkFailure(String)

    /// Authentication required or expired
    case authenticationRequired

    /// Server returned an error
    case serverError(code: Int, message: String)

    /// Database operation failed
    case databaseError(String)

    /// Rate limited by server
    case rateLimited(retryAfter: TimeInterval?)

    /// Conflict that couldn't be auto-resolved
    case unresolvedConflict(table: String)

    /// Operation timeout
    case timeout

    /// Part of a sync failed while the rest succeeded.
    ///
    /// `pushPendingChangesInternal` and `pullFromRemoteInternal` absorb their own errors — they
    /// report per-operation and per-table failures instead of throwing — so without this case a
    /// sync where everything failed was indistinguishable from one where everything worked.
    case partialFailure(failed: Int, total: Int)

    /// Unknown/generic error
    case unknown(String)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .networkFailure(let message):
            return "Network failure: \(message)"
        case .authenticationRequired:
            return "Authentication required"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .databaseError(let message):
            return "Database error: \(message)"
        case .rateLimited(let retryAfter):
            if let retry = retryAfter {
                return "Rate limited. Retry after \(Int(retry)) seconds"
            }
            return "Rate limited"
        case .unresolvedConflict(let table):
            return "Unresolved conflict in \(table)"
        case .timeout:
            return "Operation timed out"
        case .partialFailure(let failed, let total):
            return "Sync incomplete: \(failed) of \(total) operations failed"
        case .unknown(let message):
            return message
        }
    }

    // MARK: - Retryable

    /// Whether this error can potentially be resolved by retrying
    public var isRetryable: Bool {
        switch self {
        case .networkFailure, .timeout, .serverError, .rateLimited, .partialFailure:
            return true
        case .authenticationRequired, .databaseError, .unresolvedConflict, .unknown:
            return false
        }
    }

    // MARK: - Factory Methods

    /// Creates a SyncStateError from a generic Error
    public static func from(_ error: Error) -> SyncStateError {
        if let stateError = error as? SyncStateError {
            return stateError
        }

        if let syncEngineError = error as? SyncEngineError {
            switch syncEngineError {
            case .queueFailed:
                return .databaseError("Failed to queue operation")
            case .databaseError:
                return .databaseError("Database operation failed")
            case .networkError:
                return .networkFailure("Network error")
            case .notAuthenticated:
                return .authenticationRequired
            case .operationFailed(let message):
                return .unknown(message)
            }
        }

        return .unknown(error.localizedDescription)
    }
}

// MARK: - SyncState

/// Represents the current state of the sync engine.
///
/// The sync state machine uses this enum to track sync lifecycle:
/// - `.idle` - Ready to sync, no active operation
/// - `.syncing(SyncOperation)` - Active sync in progress with operation details
/// - `.error(SyncStateError, retryable: Bool)` - Sync failed with error info
/// - `.offline` - Network unavailable, waiting to retry
/// - `.suspended` - User-initiated pause or app in background
public enum SyncState: Sendable, CustomStringConvertible {
    /// Ready to sync, no active operation
    case idle

    /// Active sync in progress with operation details
    case syncing(SyncOperationType)

    /// Sync failed with error information
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - retryable: Whether the error can be resolved by retrying
    case error(SyncStateError, retryable: Bool)

    /// Network unavailable, waiting to retry when connectivity returns
    case offline

    /// Sync is suspended (app in background or user-initiated pause)
    case suspended

    // MARK: - State Properties

    /// Whether a sync operation is currently active
    public var isSyncing: Bool {
        if case .syncing = self {
            return true
        }
        return false
    }

    /// Whether the state allows starting a new sync
    public var canStartSync: Bool {
        switch self {
        case .idle, .error:
            return true
        case .syncing, .offline, .suspended:
            return false
        }
    }

    /// Whether the state represents an error condition
    public var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }

    /// Whether the state indicates we're waiting for something
    public var isWaiting: Bool {
        switch self {
        case .offline, .suspended:
            return true
        case .idle, .syncing, .error:
            return false
        }
    }

    /// The error if in error state, nil otherwise
    public var error: SyncStateError? {
        if case .error(let err, _) = self {
            return err
        }
        return nil
    }

    /// The current operation if syncing, nil otherwise
    public var currentOperation: SyncOperationType? {
        if case .syncing(let operation) = self {
            return operation
        }
        return nil
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        switch self {
        case .idle:
            return "Idle"
        case .syncing(let operation):
            return "Syncing (\(operation))"
        case .error(let error, let retryable):
            return "Error: \(error.localizedDescription) (retryable: \(retryable))"
        case .offline:
            return "Offline"
        case .suspended:
            return "Suspended"
        }
    }

    /// Short description for logging
    public var logDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .syncing(let operation):
            return "syncing:\(operation)"
        case .error(_, let retryable):
            return "error(retryable:\(retryable))"
        case .offline:
            return "offline"
        case .suspended:
            return "suspended"
        }
    }
}

// MARK: - SyncState Equatable

extension SyncState: Equatable {
    public static func == (lhs: SyncState, rhs: SyncState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.syncing(let lhsOp), .syncing(let rhsOp)):
            return lhsOp == rhsOp
        case (.error(let lhsErr, let lhsRetryable), .error(let rhsErr, let rhsRetryable)):
            return lhsErr == rhsErr && lhsRetryable == rhsRetryable
        case (.offline, .offline):
            return true
        case (.suspended, .suspended):
            return true
        default:
            return false
        }
    }
}

// MARK: - SyncStateHistoryEntry

/// An entry in the sync state history, used for debugging.
public struct SyncStateHistoryEntry: Sendable {
    /// The state that was entered
    public let state: SyncState

    /// When this state was entered
    public let timestamp: Date

    /// The previous state (for transition tracking)
    public let previousState: SyncState?

    /// Optional context/reason for the transition
    public let reason: String?

    public init(
        state: SyncState,
        timestamp: Date = Date(),
        previousState: SyncState? = nil,
        reason: String? = nil
    ) {
        self.state = state
        self.timestamp = timestamp
        self.previousState = previousState
        self.reason = reason
    }
}

extension SyncStateHistoryEntry: CustomStringConvertible {
    public var description: String {
        let formatter = ISO8601DateFormatter()
        let timeStr = formatter.string(from: timestamp)
        var desc = "[\(timeStr)] \(state.logDescription)"
        if let prev = previousState {
            desc = "[\(timeStr)] \(prev.logDescription) -> \(state.logDescription)"
        }
        if let reason = reason {
            desc += " (\(reason))"
        }
        return desc
    }
}
