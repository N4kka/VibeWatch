import Foundation
import Combine

// MARK: - SyncStateMachineProtocol

/// Protocol defining the sync state machine interface.
/// Enables testability through dependency injection and mocking.
@MainActor
public protocol SyncStateMachineProtocol: AnyObject {
    /// The current state of the sync engine
    var currentState: SyncState { get }

    /// Publisher for observing state changes
    var statePublisher: AnyPublisher<SyncState, Never> { get }

    /// Attempt to transition to a new state
    /// - Parameters:
    ///   - newState: The target state
    ///   - reason: Optional reason for the transition (for debugging)
    /// - Returns: Whether the transition was successful
    @discardableResult
    func transition(to newState: SyncState, reason: String?) -> Bool

    /// Check if a transition to the given state is valid
    /// - Parameter state: The target state to check
    /// - Returns: Whether the transition is valid from the current state
    func canTransition(to state: SyncState) -> Bool

    /// Get the recent state history for debugging
    func getHistory() -> [SyncStateHistoryEntry]
}

// MARK: - SyncStateMachine

/// Manages sync state transitions with validation and history tracking.
///
/// Valid transitions:
/// ```
/// idle -> syncing (start sync)
/// syncing -> idle (sync complete)
/// syncing -> error (sync failed)
/// syncing -> offline (network lost during sync)
/// error -> idle (retry succeeded)
/// error -> syncing (manual retry)
/// offline -> idle (network restored, auto-retry succeeded)
/// offline -> syncing (network restored)
/// any -> suspended (app backgrounded)
/// suspended -> idle (app foregrounded)
/// ```
@MainActor
public final class SyncStateMachine: ObservableObject, SyncStateMachineProtocol {

    // MARK: - Published State

    /// The current state of the sync engine (published for SwiftUI)
    @Published public private(set) var currentState: SyncState = .idle

    /// Publisher for observing state changes
    public var statePublisher: AnyPublisher<SyncState, Never> {
        $currentState.eraseToAnyPublisher()
    }

    // MARK: - Configuration

    /// Maximum number of history entries to keep
    private let maxHistorySize: Int

    // MARK: - Internal State

    /// History of state transitions for debugging
    private var history: [SyncStateHistoryEntry] = []

    /// Lock for thread-safe history access
    private let historyLock = NSLock()

    // MARK: - Notification Names

    public static let stateChangedNotification = Notification.Name("SyncStateMachine.stateChanged")

    // MARK: - Initialization

    public init(initialState: SyncState = .idle, maxHistorySize: Int = 10) {
        self.currentState = initialState
        self.maxHistorySize = maxHistorySize

        // Record initial state in history
        let entry = SyncStateHistoryEntry(
            state: initialState,
            previousState: nil,
            reason: "Initial state"
        )
        history.append(entry)

        Logger.info("[SyncStateMachine] Initialized with state: \(initialState.logDescription)")
    }

    // MARK: - State Transitions

    /// Attempt to transition to a new state.
    ///
    /// This method validates the transition and only applies it if valid.
    /// Invalid transitions are logged but not applied.
    ///
    /// - Parameters:
    ///   - newState: The target state
    ///   - reason: Optional reason for the transition (for debugging)
    /// - Returns: Whether the transition was successful
    @discardableResult
    public func transition(to newState: SyncState, reason: String? = nil) -> Bool {
        let oldState = currentState

        // Skip if transitioning to same state (except for error which may have different details)
        if oldState == newState {
            Logger.debug("[SyncStateMachine] Skipping transition to same state: \(newState.logDescription)")
            return true
        }

        // Check if transition is valid
        guard canTransition(to: newState) else {
            Logger.warning("[SyncStateMachine] Invalid transition: \(oldState.logDescription) -> \(newState.logDescription)")
            return false
        }

        // Apply transition
        currentState = newState

        // Record in history
        recordTransition(from: oldState, to: newState, reason: reason)

        // Post notification
        postStateChangeNotification(from: oldState, to: newState, reason: reason)

        Logger.info("[SyncStateMachine] Transition: \(oldState.logDescription) -> \(newState.logDescription)\(reason.map { " (\($0))" } ?? "")")

        return true
    }

    /// Check if a transition to the given state is valid from the current state.
    ///
    /// Valid transitions:
    /// - idle -> syncing: Start sync
    /// - syncing -> idle: Sync complete
    /// - syncing -> error: Sync failed
    /// - syncing -> offline: Network lost during sync
    /// - error -> idle: Retry succeeded
    /// - error -> syncing: Manual retry
    /// - offline -> idle: Network restored, auto-retry succeeded
    /// - offline -> syncing: Network restored, starting retry
    /// - any -> suspended: App backgrounded
    /// - suspended -> idle: App foregrounded
    /// - suspended -> syncing: Resume directly to sync (for quick foreground)
    /// - suspended -> offline: Resume to offline state
    ///
    /// - Parameter state: The target state to check
    /// - Returns: Whether the transition is valid
    public func canTransition(to state: SyncState) -> Bool {
        // Suspended can be entered from any state (app can go to background anytime)
        if case .suspended = state {
            return true
        }

        switch currentState {
        case .idle:
            // From idle, can only start syncing
            if case .syncing = state { return true }
            // Can also go offline if network is lost while idle
            if case .offline = state { return true }
            return false

        case .syncing:
            // From syncing, can complete (idle), fail (error), or lose network (offline)
            switch state {
            case .idle, .error, .offline:
                return true
            default:
                return false
            }

        case .error:
            // From error, can retry (syncing) or succeed on retry (idle)
            switch state {
            case .idle, .syncing:
                return true
            // Can also go offline if network is lost
            case .offline:
                return true
            default:
                return false
            }

        case .offline:
            // From offline, can start syncing when network returns, or go directly to idle
            switch state {
            case .idle, .syncing:
                return true
            // Can stay in error state if needed
            case .error:
                return true
            default:
                return false
            }

        case .suspended:
            // From suspended, can resume to idle, syncing, or offline
            switch state {
            case .idle, .syncing, .offline, .error:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - History

    /// Get the recent state history for debugging.
    /// - Returns: Array of history entries, most recent last
    public func getHistory() -> [SyncStateHistoryEntry] {
        historyLock.lock()
        defer { historyLock.unlock() }
        return history
    }

    /// Clear the state history (useful for testing)
    public func clearHistory() {
        historyLock.lock()
        defer { historyLock.unlock() }
        history.removeAll()
    }

    // MARK: - Convenience Methods

    /// Start a sync operation (transition from idle/error to syncing)
    /// - Parameters:
    ///   - operation: The type of sync operation
    ///   - reason: Optional reason for the sync
    /// - Returns: Whether the transition was successful
    @discardableResult
    public func startSync(_ operation: SyncOperationType, reason: String? = nil) -> Bool {
        return transition(to: .syncing(operation), reason: reason ?? "Starting \(operation.logDescription)")
    }

    /// Complete a sync operation (transition from syncing to idle)
    /// - Parameter reason: Optional reason/details about completion
    /// - Returns: Whether the transition was successful
    @discardableResult
    public func completeSync(reason: String? = nil) -> Bool {
        return transition(to: .idle, reason: reason ?? "Sync completed successfully")
    }

    /// Fail a sync operation with an error
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - reason: Optional additional context
    /// - Returns: Whether the transition was successful
    @discardableResult
    public func failSync(with error: SyncStateError, reason: String? = nil) -> Bool {
        return transition(
            to: .error(error, retryable: error.isRetryable),
            reason: reason ?? error.localizedDescription
        )
    }

    /// Mark as offline (network unavailable)
    /// - Parameter reason: Optional reason for going offline
    /// - Returns: Whether the transition was successful
    @discardableResult
    public func goOffline(reason: String? = nil) -> Bool {
        return transition(to: .offline, reason: reason ?? "Network unavailable")
    }

    /// Mark as online/idle (network restored)
    /// - Parameter reason: Optional reason
    /// - Returns: Whether the transition was successful
    @discardableResult
    public func goOnline(reason: String? = nil) -> Bool {
        return transition(to: .idle, reason: reason ?? "Network restored")
    }

    /// Suspend sync operations (app backgrounded)
    /// - Parameter reason: Optional reason for suspension
    /// - Returns: Whether the transition was successful
    @discardableResult
    public func suspend(reason: String? = nil) -> Bool {
        return transition(to: .suspended, reason: reason ?? "App suspended")
    }

    /// Resume from suspension
    /// - Parameters:
    ///   - toState: The state to resume to (defaults to .idle)
    ///   - reason: Optional reason
    /// - Returns: Whether the transition was successful
    @discardableResult
    public func resume(to toState: SyncState = .idle, reason: String? = nil) -> Bool {
        guard case .suspended = currentState else {
            Logger.warning("[SyncStateMachine] Cannot resume - not in suspended state")
            return false
        }
        return transition(to: toState, reason: reason ?? "App resumed")
    }

    // MARK: - Private Methods

    private func recordTransition(from oldState: SyncState, to newState: SyncState, reason: String?) {
        historyLock.lock()
        defer { historyLock.unlock() }

        let entry = SyncStateHistoryEntry(
            state: newState,
            previousState: oldState,
            reason: reason
        )
        history.append(entry)

        // Trim history if needed
        if history.count > maxHistorySize {
            history.removeFirst(history.count - maxHistorySize)
        }
    }

    private func postStateChangeNotification(from oldState: SyncState, to newState: SyncState, reason: String?) {
        var userInfo: [String: Any] = [
            "oldState": oldState.logDescription,
            "newState": newState.logDescription
        ]
        if let reason = reason {
            userInfo["reason"] = reason
        }

        NotificationCenter.default.post(
            name: SyncStateMachine.stateChangedNotification,
            object: self,
            userInfo: userInfo
        )
    }
}

// MARK: - Debug Extensions

extension SyncStateMachine {
    /// Returns a formatted string of the state history for debugging
    public func historyDescription() -> String {
        let entries = getHistory()
        if entries.isEmpty {
            return "No history"
        }
        return entries.map { $0.description }.joined(separator: "\n")
    }

    /// Logs the current state and recent history
    public func logStateInfo() {
        Logger.debug("[SyncStateMachine] Current state: \(currentState.logDescription)")
        Logger.debug("[SyncStateMachine] History:\n\(historyDescription())")
    }
}
