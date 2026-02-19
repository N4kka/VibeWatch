import XCTest
@testable import VibeWatchApp

/// Unit tests for SyncState, SyncOperationType, and SyncStateMachine
@MainActor
final class SyncStateMachineTests: XCTestCase {

    var stateMachine: SyncStateMachine!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        stateMachine = SyncStateMachine()
    }

    override func tearDown() async throws {
        stateMachine = nil
        try await super.tearDown()
    }

    // MARK: - SyncOperationType Tests

    func testSyncOperationTypeDescriptions() {
        XCTAssertEqual(SyncOperationType.push.description, "Push")
        XCTAssertEqual(SyncOperationType.pull.description, "Pull")
        XCTAssertEqual(SyncOperationType.fullSync.description, "Full Sync")

        XCTAssertEqual(SyncOperationType.push.logDescription, "pushing local changes")
        XCTAssertEqual(SyncOperationType.pull.logDescription, "pulling remote changes")
        XCTAssertEqual(SyncOperationType.fullSync.logDescription, "performing full sync")
    }

    // MARK: - SyncStateError Tests

    func testSyncStateErrorRetryable() {
        // Retryable errors
        XCTAssertTrue(SyncStateError.networkFailure("test").isRetryable)
        XCTAssertTrue(SyncStateError.timeout.isRetryable)
        XCTAssertTrue(SyncStateError.serverError(code: 500, message: "test").isRetryable)
        XCTAssertTrue(SyncStateError.rateLimited(retryAfter: 60).isRetryable)

        // Non-retryable errors
        XCTAssertFalse(SyncStateError.authenticationRequired.isRetryable)
        XCTAssertFalse(SyncStateError.databaseError("test").isRetryable)
        XCTAssertFalse(SyncStateError.unresolvedConflict(table: "test").isRetryable)
        XCTAssertFalse(SyncStateError.unknown("test").isRetryable)
    }

    func testSyncStateErrorDescriptions() {
        XCTAssertEqual(
            SyncStateError.networkFailure("Connection lost").errorDescription,
            "Network failure: Connection lost"
        )
        XCTAssertEqual(
            SyncStateError.authenticationRequired.errorDescription,
            "Authentication required"
        )
        XCTAssertEqual(
            SyncStateError.serverError(code: 500, message: "Internal error").errorDescription,
            "Server error (500): Internal error"
        )
        XCTAssertEqual(
            SyncStateError.rateLimited(retryAfter: 30).errorDescription,
            "Rate limited. Retry after 30 seconds"
        )
        XCTAssertEqual(
            SyncStateError.rateLimited(retryAfter: nil).errorDescription,
            "Rate limited"
        )
        XCTAssertEqual(
            SyncStateError.timeout.errorDescription,
            "Operation timed out"
        )
    }

    func testSyncStateErrorFromSyncEngineError() {
        XCTAssertEqual(
            SyncStateError.from(SyncEngineError.queueFailed),
            SyncStateError.databaseError("Failed to queue operation")
        )
        XCTAssertEqual(
            SyncStateError.from(SyncEngineError.notAuthenticated),
            SyncStateError.authenticationRequired
        )
        XCTAssertEqual(
            SyncStateError.from(SyncEngineError.networkError),
            SyncStateError.networkFailure("Network error")
        )
    }

    // MARK: - SyncState Tests

    func testSyncStateProperties() {
        // Idle state
        let idle = SyncState.idle
        XCTAssertFalse(idle.isSyncing)
        XCTAssertTrue(idle.canStartSync)
        XCTAssertFalse(idle.isError)
        XCTAssertFalse(idle.isWaiting)
        XCTAssertNil(idle.error)
        XCTAssertNil(idle.currentOperation)

        // Syncing state
        let syncing = SyncState.syncing(.fullSync)
        XCTAssertTrue(syncing.isSyncing)
        XCTAssertFalse(syncing.canStartSync)
        XCTAssertFalse(syncing.isError)
        XCTAssertFalse(syncing.isWaiting)
        XCTAssertNil(syncing.error)
        XCTAssertEqual(syncing.currentOperation, .fullSync)

        // Error state
        let error = SyncState.error(.networkFailure("test"), retryable: true)
        XCTAssertFalse(error.isSyncing)
        XCTAssertTrue(error.canStartSync)
        XCTAssertTrue(error.isError)
        XCTAssertFalse(error.isWaiting)
        XCTAssertNotNil(error.error)
        XCTAssertNil(error.currentOperation)

        // Offline state
        let offline = SyncState.offline
        XCTAssertFalse(offline.isSyncing)
        XCTAssertFalse(offline.canStartSync)
        XCTAssertFalse(offline.isError)
        XCTAssertTrue(offline.isWaiting)
        XCTAssertNil(offline.error)

        // Suspended state
        let suspended = SyncState.suspended
        XCTAssertFalse(suspended.isSyncing)
        XCTAssertFalse(suspended.canStartSync)
        XCTAssertFalse(suspended.isError)
        XCTAssertTrue(suspended.isWaiting)
    }

    func testSyncStateDescriptions() {
        XCTAssertEqual(SyncState.idle.description, "Idle")
        XCTAssertEqual(SyncState.syncing(.push).description, "Syncing (Push)")
        XCTAssertEqual(SyncState.offline.description, "Offline")
        XCTAssertEqual(SyncState.suspended.description, "Suspended")

        XCTAssertEqual(SyncState.idle.logDescription, "idle")
        XCTAssertEqual(SyncState.syncing(.pull).logDescription, "syncing:Pull")
        XCTAssertEqual(SyncState.offline.logDescription, "offline")
        XCTAssertEqual(SyncState.suspended.logDescription, "suspended")
    }

    // MARK: - State Machine Initialization Tests

    func testInitialState() {
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testCustomInitialState() {
        let machine = SyncStateMachine(initialState: .offline)
        XCTAssertEqual(machine.currentState, .offline)
    }

    // MARK: - Valid Transition Tests

    func testIdleToSyncing() {
        XCTAssertTrue(stateMachine.canTransition(to: .syncing(.fullSync)))
        XCTAssertTrue(stateMachine.transition(to: .syncing(.fullSync)))
        XCTAssertEqual(stateMachine.currentState, .syncing(.fullSync))
    }

    func testIdleToOffline() {
        XCTAssertTrue(stateMachine.canTransition(to: .offline))
        XCTAssertTrue(stateMachine.transition(to: .offline))
        XCTAssertEqual(stateMachine.currentState, .offline)
    }

    func testSyncingToIdle() {
        stateMachine.transition(to: .syncing(.push))
        XCTAssertTrue(stateMachine.canTransition(to: .idle))
        XCTAssertTrue(stateMachine.transition(to: .idle))
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testSyncingToError() {
        stateMachine.transition(to: .syncing(.pull))
        let error = SyncStateError.networkFailure("test")
        XCTAssertTrue(stateMachine.canTransition(to: .error(error, retryable: true)))
        XCTAssertTrue(stateMachine.transition(to: .error(error, retryable: true)))
        XCTAssertTrue(stateMachine.currentState.isError)
    }

    func testSyncingToOffline() {
        stateMachine.transition(to: .syncing(.fullSync))
        XCTAssertTrue(stateMachine.canTransition(to: .offline))
        XCTAssertTrue(stateMachine.transition(to: .offline))
        XCTAssertEqual(stateMachine.currentState, .offline)
    }

    func testErrorToIdle() {
        stateMachine.transition(to: .syncing(.push))
        stateMachine.transition(to: .error(.networkFailure("test"), retryable: true))
        XCTAssertTrue(stateMachine.canTransition(to: .idle))
        XCTAssertTrue(stateMachine.transition(to: .idle))
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testErrorToSyncing() {
        stateMachine.transition(to: .syncing(.push))
        stateMachine.transition(to: .error(.networkFailure("test"), retryable: true))
        XCTAssertTrue(stateMachine.canTransition(to: .syncing(.fullSync)))
        XCTAssertTrue(stateMachine.transition(to: .syncing(.fullSync)))
        XCTAssertEqual(stateMachine.currentState, .syncing(.fullSync))
    }

    func testOfflineToIdle() {
        stateMachine.transition(to: .offline)
        XCTAssertTrue(stateMachine.canTransition(to: .idle))
        XCTAssertTrue(stateMachine.transition(to: .idle))
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testOfflineToSyncing() {
        stateMachine.transition(to: .offline)
        XCTAssertTrue(stateMachine.canTransition(to: .syncing(.fullSync)))
        XCTAssertTrue(stateMachine.transition(to: .syncing(.fullSync)))
        XCTAssertEqual(stateMachine.currentState, .syncing(.fullSync))
    }

    func testAnyToSuspended() {
        // From idle
        XCTAssertTrue(stateMachine.canTransition(to: .suspended))
        stateMachine.transition(to: .suspended)
        XCTAssertEqual(stateMachine.currentState, .suspended)

        // Reset and test from syncing
        stateMachine = SyncStateMachine()
        stateMachine.transition(to: .syncing(.push))
        XCTAssertTrue(stateMachine.canTransition(to: .suspended))
        stateMachine.transition(to: .suspended)
        XCTAssertEqual(stateMachine.currentState, .suspended)

        // Reset and test from error
        stateMachine = SyncStateMachine()
        stateMachine.transition(to: .syncing(.push))
        stateMachine.transition(to: .error(.timeout, retryable: true))
        XCTAssertTrue(stateMachine.canTransition(to: .suspended))
        stateMachine.transition(to: .suspended)
        XCTAssertEqual(stateMachine.currentState, .suspended)

        // Reset and test from offline
        stateMachine = SyncStateMachine()
        stateMachine.transition(to: .offline)
        XCTAssertTrue(stateMachine.canTransition(to: .suspended))
        stateMachine.transition(to: .suspended)
        XCTAssertEqual(stateMachine.currentState, .suspended)
    }

    func testSuspendedToIdle() {
        stateMachine.transition(to: .suspended)
        XCTAssertTrue(stateMachine.canTransition(to: .idle))
        XCTAssertTrue(stateMachine.transition(to: .idle))
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testSuspendedToSyncing() {
        stateMachine.transition(to: .suspended)
        XCTAssertTrue(stateMachine.canTransition(to: .syncing(.fullSync)))
        XCTAssertTrue(stateMachine.transition(to: .syncing(.fullSync)))
        XCTAssertEqual(stateMachine.currentState, .syncing(.fullSync))
    }

    func testSuspendedToOffline() {
        stateMachine.transition(to: .suspended)
        XCTAssertTrue(stateMachine.canTransition(to: .offline))
        XCTAssertTrue(stateMachine.transition(to: .offline))
        XCTAssertEqual(stateMachine.currentState, .offline)
    }

    // MARK: - Invalid Transition Tests

    func testIdleToIdle() {
        // Transitioning to same state should succeed but not add to history
        let historyBefore = stateMachine.getHistory().count
        XCTAssertTrue(stateMachine.transition(to: .idle))
        let historyAfter = stateMachine.getHistory().count
        XCTAssertEqual(historyBefore, historyAfter)
    }

    func testIdleToError() {
        // Cannot go directly from idle to error
        XCTAssertFalse(stateMachine.canTransition(to: .error(.timeout, retryable: true)))
        XCTAssertFalse(stateMachine.transition(to: .error(.timeout, retryable: true)))
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testSyncingToSyncing() {
        stateMachine.transition(to: .syncing(.push))
        // Cannot start another sync while syncing
        XCTAssertFalse(stateMachine.canTransition(to: .syncing(.pull)))
        XCTAssertFalse(stateMachine.transition(to: .syncing(.pull)))
        XCTAssertEqual(stateMachine.currentState, .syncing(.push))
    }

    func testErrorToError() {
        stateMachine.transition(to: .syncing(.push))
        stateMachine.transition(to: .error(.timeout, retryable: true))
        // Cannot transition from error to error
        XCTAssertFalse(stateMachine.canTransition(to: .error(.networkFailure("new"), retryable: false)))
    }

    func testOfflineToError() {
        stateMachine.transition(to: .offline)
        // Offline to error is actually valid (can retry and fail)
        XCTAssertTrue(stateMachine.canTransition(to: .error(.timeout, retryable: true)))
    }

    // MARK: - Convenience Method Tests

    func testStartSync() {
        XCTAssertTrue(stateMachine.startSync(.fullSync))
        XCTAssertEqual(stateMachine.currentState, .syncing(.fullSync))

        // Cannot start while syncing
        XCTAssertFalse(stateMachine.startSync(.push))
        XCTAssertEqual(stateMachine.currentState, .syncing(.fullSync))
    }

    func testCompleteSync() {
        stateMachine.startSync(.push)
        XCTAssertTrue(stateMachine.completeSync())
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testFailSync() {
        stateMachine.startSync(.pull)
        XCTAssertTrue(stateMachine.failSync(with: .networkFailure("test")))
        XCTAssertTrue(stateMachine.currentState.isError)
    }

    func testGoOffline() {
        XCTAssertTrue(stateMachine.goOffline())
        XCTAssertEqual(stateMachine.currentState, .offline)
    }

    func testGoOnline() {
        stateMachine.goOffline()
        XCTAssertTrue(stateMachine.goOnline())
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testSuspendAndResume() {
        XCTAssertTrue(stateMachine.suspend())
        XCTAssertEqual(stateMachine.currentState, .suspended)

        XCTAssertTrue(stateMachine.resume(to: .idle))
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testResumeNotFromSuspended() {
        // Resume should fail if not in suspended state
        XCTAssertFalse(stateMachine.resume())
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    // MARK: - History Tests

    func testHistoryTracking() {
        stateMachine.startSync(.fullSync)
        stateMachine.completeSync()
        stateMachine.startSync(.push)
        stateMachine.failSync(with: .timeout)

        let history = stateMachine.getHistory()
        XCTAssertEqual(history.count, 5) // initial + 4 transitions

        // Verify first entry is initial state
        XCTAssertEqual(history[0].state, .idle)
        XCTAssertNil(history[0].previousState)

        // Verify subsequent entries have previous state
        XCTAssertEqual(history[1].state, .syncing(.fullSync))
        XCTAssertEqual(history[1].previousState, .idle)
    }

    func testHistoryLimit() {
        let machine = SyncStateMachine(initialState: .idle, maxHistorySize: 3)

        // Make more transitions than the limit
        machine.transition(to: .syncing(.push))
        machine.transition(to: .idle)
        machine.transition(to: .syncing(.pull))
        machine.transition(to: .idle)
        machine.transition(to: .offline)

        let history = machine.getHistory()
        XCTAssertEqual(history.count, 3)

        // Should have the last 3 states
        XCTAssertEqual(history[2].state, .offline)
    }

    func testClearHistory() {
        stateMachine.startSync(.push)
        stateMachine.completeSync()
        XCTAssertGreaterThan(stateMachine.getHistory().count, 1)

        stateMachine.clearHistory()
        XCTAssertEqual(stateMachine.getHistory().count, 0)
    }

    func testHistoryDescription() {
        stateMachine.startSync(.fullSync, reason: "Test sync")
        stateMachine.completeSync(reason: "Done")

        let description = stateMachine.historyDescription()
        XCTAssertTrue(description.contains("idle"))
        XCTAssertTrue(description.contains("syncing"))
    }

    // MARK: - Full Workflow Tests

    func testTypicalSyncWorkflow() {
        // Start idle
        XCTAssertEqual(stateMachine.currentState, .idle)

        // Start sync
        XCTAssertTrue(stateMachine.startSync(.fullSync, reason: "App launch"))
        XCTAssertEqual(stateMachine.currentState, .syncing(.fullSync))

        // Complete sync
        XCTAssertTrue(stateMachine.completeSync(reason: "Success"))
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testSyncFailureAndRetry() {
        // Start sync
        stateMachine.startSync(.push)

        // Fail with retryable error
        stateMachine.failSync(with: .networkFailure("Connection lost"))
        XCTAssertTrue(stateMachine.currentState.isError)

        // Retry
        XCTAssertTrue(stateMachine.startSync(.push, reason: "Retry"))
        XCTAssertEqual(stateMachine.currentState, .syncing(.push))

        // Success
        stateMachine.completeSync()
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testOfflineWorkflow() {
        // Go offline
        stateMachine.goOffline(reason: "Network lost")
        XCTAssertEqual(stateMachine.currentState, .offline)

        // Network restored
        stateMachine.goOnline(reason: "Network restored")
        XCTAssertEqual(stateMachine.currentState, .idle)

        // Start sync after coming online
        stateMachine.startSync(.fullSync)
        XCTAssertEqual(stateMachine.currentState, .syncing(.fullSync))
    }

    func testBackgroundForegroundWorkflow() {
        // Start syncing
        stateMachine.startSync(.push)

        // App goes to background
        stateMachine.suspend(reason: "App backgrounded")
        XCTAssertEqual(stateMachine.currentState, .suspended)

        // App returns to foreground
        XCTAssertTrue(stateMachine.resume(to: .idle, reason: "App resumed"))
        XCTAssertEqual(stateMachine.currentState, .idle)
    }

    func testNetworkLostDuringSync() {
        // Start sync
        stateMachine.startSync(.fullSync)

        // Network lost during sync
        stateMachine.transition(to: .offline, reason: "Network lost during sync")
        XCTAssertEqual(stateMachine.currentState, .offline)

        // Network restored
        stateMachine.goOnline()
        XCTAssertEqual(stateMachine.currentState, .idle)
    }
}

// MARK: - SyncStateHistoryEntry Tests

@MainActor
final class SyncStateHistoryEntryTests: XCTestCase {

    func testHistoryEntryDescription() {
        let entry = SyncStateHistoryEntry(
            state: .syncing(.push),
            previousState: .idle,
            reason: "User action"
        )

        let description = entry.description
        XCTAssertTrue(description.contains("idle"))
        XCTAssertTrue(description.contains("syncing"))
        XCTAssertTrue(description.contains("User action"))
    }

    func testHistoryEntryWithoutPreviousState() {
        let entry = SyncStateHistoryEntry(
            state: .idle,
            previousState: nil,
            reason: "Initial"
        )

        let description = entry.description
        XCTAssertTrue(description.contains("idle"))
        XCTAssertTrue(description.contains("Initial"))
        XCTAssertFalse(description.contains("->"))
    }
}
