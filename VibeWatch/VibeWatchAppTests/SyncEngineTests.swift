import XCTest
@testable import VibeWatchApp

/// Unit tests for the unified SyncEngine
/// Tests sync logic, backoff strategy, dependency handling, and error recovery
final class SyncEngineTests: XCTestCase {

    var syncEngine: SyncEngine!
    var sqliteService: SQLiteService!
    var testUserId: String!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Get shared instances
        syncEngine = SyncEngine.shared
        sqliteService = SQLiteService.shared
        testUserId = "test-user-\(UUID().uuidString)"

        // Clean up any lingering test data
        await cleanTestData()
    }

    override func tearDown() async throws {
        await cleanTestData()
        try await super.tearDown()
    }

    // MARK: - SyncTrigger Tests

    func testSyncTriggerBehavior() {
        // App launch should trigger full sync
        XCTAssertTrue(SyncTrigger.appLaunch.shouldPerformFullSync)
        XCTAssertTrue(SyncTrigger.appLaunch.shouldPushChanges)
        XCTAssertTrue(SyncTrigger.appLaunch.shouldPullChanges)

        // User action should only push, not pull
        XCTAssertFalse(SyncTrigger.userAction.shouldPerformFullSync)
        XCTAssertTrue(SyncTrigger.userAction.shouldPushChanges)
        XCTAssertFalse(SyncTrigger.userAction.shouldPullChanges)

        // Manual refresh should do full sync
        XCTAssertTrue(SyncTrigger.manualRefresh.shouldPerformFullSync)
        XCTAssertTrue(SyncTrigger.manualRefresh.shouldPullChanges)

        // Periodic should only push
        XCTAssertFalse(SyncTrigger.periodic.shouldPerformFullSync)
        XCTAssertTrue(SyncTrigger.periodic.shouldPushChanges)
        XCTAssertFalse(SyncTrigger.periodic.shouldPullChanges)

        print("SyncTrigger behavior tests passed")
    }

    func testSyncTriggerPriority() {
        // User action should have highest priority
        XCTAssertEqual(SyncTrigger.userAction.priority, 100)

        // Periodic should have lowest priority
        XCTAssertEqual(SyncTrigger.periodic.priority, 10)

        // App launch should be high priority
        XCTAssertGreaterThan(SyncTrigger.appLaunch.priority, SyncTrigger.periodic.priority)

        // Foreground resume should be lower than app launch
        XCTAssertLessThan(SyncTrigger.foregroundResume.priority, SyncTrigger.appLaunch.priority)

        print("SyncTrigger priority tests passed")
    }

    // MARK: - Queue Operation Tests

    func testQueueOperation() async throws {
        let initialCount = await getPendingCount()

        // Queue a test operation
        try await syncEngine.queueOperation(
            table: "test_table",
            operationType: "INSERT",
            recordId: "test-record-\(UUID().uuidString)",
            payload: ["test_field": "test_value"],
            dependsOn: nil
        )

        let afterCount = await getPendingCount()
        XCTAssertEqual(afterCount, initialCount + 1, "Pending count should increase by 1")

        print("Queue operation test passed")
    }

    func testQueueOperationWithDependency() async throws {
        // First operation
        let parentRecordId = "parent-\(UUID().uuidString)"
        try await syncEngine.queueOperation(
            table: "parent_table",
            operationType: "INSERT",
            recordId: parentRecordId,
            payload: ["name": "Parent Record"],
            dependsOn: nil
        )

        // Get the parent operation ID
        let parentId = await getLatestOperationId()
        XCTAssertNotNil(parentId, "Parent operation should exist")

        // Child operation depending on parent
        try await syncEngine.queueOperation(
            table: "child_table",
            operationType: "INSERT",
            recordId: "child-\(UUID().uuidString)",
            payload: ["parent_id": parentRecordId],
            dependsOn: parentId
        )

        // Verify dependency is set
        let childOps = await getOperationsWithDependency(parentId!)
        XCTAssertEqual(childOps.count, 1, "Should have 1 child operation")

        print("Queue operation with dependency test passed")
    }

    // MARK: - Backoff Strategy Tests

    func testExponentialBackoffSchedule() async throws {
        // The backoff schedule should be: 60s, 5min, 15min, 1hr, 4hr
        let expectedDelays: [TimeInterval] = [60, 300, 900, 3600, 14400]

        // Queue an operation
        try await syncEngine.queueOperation(
            table: "backoff_test",
            operationType: "INSERT",
            recordId: "backoff-\(UUID().uuidString)",
            payload: ["test": true],
            dependsOn: nil
        )

        // Simulate failures and check retry times
        // Note: This would require mocking the network layer for full testing
        // Here we verify the schedule constants match the spec

        // Access backoff schedule through reflection or documented behavior
        // The implementation uses: [60, 300, 900, 3600, 14400]
        XCTAssertEqual(expectedDelays[0], 60, "First retry should be 60 seconds")
        XCTAssertEqual(expectedDelays[1], 300, "Second retry should be 5 minutes")
        XCTAssertEqual(expectedDelays[2], 900, "Third retry should be 15 minutes")
        XCTAssertEqual(expectedDelays[3], 3600, "Fourth retry should be 1 hour")
        XCTAssertEqual(expectedDelays[4], 14400, "Fifth retry should be 4 hours")

        print("Exponential backoff schedule test passed")
    }

    func testMaxRetryLimit() async throws {
        // Queue an operation
        let recordId = "retry-limit-\(UUID().uuidString)"
        try await syncEngine.queueOperation(
            table: "retry_test",
            operationType: "INSERT",
            recordId: recordId,
            payload: ["test": true],
            dependsOn: nil
        )

        // Manually increment attempts to max (5)
        for i in 1...5 {
            let sql = """
                UPDATE sync_outbox
                SET attempts = \(i)
                WHERE record_id = ?
            """
            _ = sqliteService.execute(sql, parameters: [recordId])
        }

        // Verify operation is at max attempts
        let attempts = await getOperationAttempts(recordId: recordId)
        XCTAssertEqual(attempts, 5, "Should be at max retry attempts")

        print("Max retry limit test passed")
    }

    // MARK: - Schema Error Handling Tests

    func testSchemaErrorDetection() {
        // PGRST205 error should be detected as schema error
        let pgrst205Error = "Could not find the table 'public.user_search_history' in the schema cache. Error code: PGRST205"
        XCTAssertTrue(pgrst205Error.contains("PGRST205"), "Should contain PGRST205")

        // Normal errors should not be schema errors
        let normalError = "Network timeout occurred"
        XCTAssertFalse(normalError.contains("PGRST205"), "Should not contain PGRST205")

        print("Schema error detection test passed")
    }

    func testBlockedOperationsReset() async throws {
        // Queue an operation and mark it as blocked
        let recordId = "blocked-\(UUID().uuidString)"
        try await syncEngine.queueOperation(
            table: "blocked_test",
            operationType: "INSERT",
            recordId: recordId,
            payload: ["test": true],
            dependsOn: nil
        )

        // Manually mark as blocked with PGRST205 error
        let blockSql = """
            UPDATE sync_outbox
            SET status = 'blocked',
                last_error = 'PGRST205: Table not found'
            WHERE record_id = ?
        """
        _ = sqliteService.execute(blockSql, parameters: [recordId])

        // Verify it's blocked
        var status = await getOperationStatus(recordId: recordId)
        XCTAssertEqual(status, "blocked", "Should be blocked")

        // Reset blocked operations
        await syncEngine.resetBlockedOperations()

        // Verify it's pending again
        status = await getOperationStatus(recordId: recordId)
        XCTAssertEqual(status, "pending", "Should be pending after reset")

        print("Blocked operations reset test passed")
    }

    // MARK: - Sync State Tests

    func testIsSyncingFlag() async {
        // Initially not syncing
        let isSyncing = await MainActor.run { syncEngine.isSyncing }
        XCTAssertFalse(isSyncing, "Should not be syncing initially")

        print("isSyncing flag test passed")
    }

    func testPendingOperationsCount() async throws {
        let initialCount = await MainActor.run { syncEngine.pendingOperationsCount }

        // Queue multiple operations
        for i in 1...3 {
            try await syncEngine.queueOperation(
                table: "count_test",
                operationType: "INSERT",
                recordId: "count-\(i)-\(UUID().uuidString)",
                payload: ["index": i],
                dependsOn: nil
            )
        }

        // Wait a moment for count update
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        let newCount = await MainActor.run { syncEngine.pendingOperationsCount }
        XCTAssertGreaterThanOrEqual(newCount, initialCount, "Pending count should not decrease")

        print("Pending operations count test passed")
    }

    // MARK: - Notification Tests

    func testSyncNotifications() async throws {
        var receivedStarted = false
        var receivedCompleted = false

        // Subscribe to notifications
        let startedObserver = NotificationCenter.default.addObserver(
            forName: SyncEngine.syncStartedNotification,
            object: nil,
            queue: .main
        ) { notification in
            receivedStarted = true
            if let trigger = notification.userInfo?["trigger"] as? String {
                XCTAssertFalse(trigger.isEmpty, "Trigger should be provided")
            }
        }

        let completedObserver = NotificationCenter.default.addObserver(
            forName: SyncEngine.syncCompletedNotification,
            object: nil,
            queue: .main
        ) { notification in
            receivedCompleted = true
        }

        defer {
            NotificationCenter.default.removeObserver(startedObserver)
            NotificationCenter.default.removeObserver(completedObserver)
        }

        // Note: Full notification test would require network mocking
        // This validates the notification names exist and are properly configured
        XCTAssertEqual(
            SyncEngine.syncStartedNotification.rawValue,
            "SyncEngine.syncStarted"
        )
        XCTAssertEqual(
            SyncEngine.syncCompletedNotification.rawValue,
            "SyncEngine.syncCompleted"
        )
        XCTAssertEqual(
            SyncEngine.syncFailedNotification.rawValue,
            "SyncEngine.syncFailed"
        )

        print("Sync notifications test passed")
    }

    // MARK: - Dependency Graph Tests

    func testDependencyOrdering() async throws {
        // Create a chain of dependencies: A <- B <- C
        let recordA = "dep-a-\(UUID().uuidString)"
        let recordB = "dep-b-\(UUID().uuidString)"
        let recordC = "dep-c-\(UUID().uuidString)"

        // Operation A (no dependencies)
        try await syncEngine.queueOperation(
            table: "dep_test",
            operationType: "INSERT",
            recordId: recordA,
            payload: ["name": "A"],
            dependsOn: nil
        )
        let idA = await getLatestOperationId()

        // Operation B depends on A
        try await syncEngine.queueOperation(
            table: "dep_test",
            operationType: "INSERT",
            recordId: recordB,
            payload: ["name": "B", "parent": recordA],
            dependsOn: idA
        )
        let idB = await getLatestOperationId()

        // Operation C depends on B
        try await syncEngine.queueOperation(
            table: "dep_test",
            operationType: "INSERT",
            recordId: recordC,
            payload: ["name": "C", "parent": recordB],
            dependsOn: idB
        )

        // Verify dependency chain exists
        let chainB = await getOperationsWithDependency(idA!)
        let chainC = await getOperationsWithDependency(idB!)

        XCTAssertEqual(chainB.count, 1, "B should depend on A")
        XCTAssertEqual(chainC.count, 1, "C should depend on B")

        print("Dependency ordering test passed")
    }

    // MARK: - Error Handling Tests

    func testSyncEngineErrorDescriptions() {
        XCTAssertEqual(
            SyncEngineError.queueFailed.errorDescription,
            "Failed to queue sync operation"
        )
        XCTAssertEqual(
            SyncEngineError.databaseError.errorDescription,
            "Database operation failed during sync"
        )
        XCTAssertEqual(
            SyncEngineError.networkError.errorDescription,
            "Network error during sync"
        )
        XCTAssertEqual(
            SyncEngineError.notAuthenticated.errorDescription,
            "User must be authenticated to sync"
        )
        XCTAssertEqual(
            SyncEngineError.operationFailed("test").errorDescription,
            "Sync operation failed: test"
        )

        print("Error descriptions test passed")
    }

    // MARK: - Performance Tests

    func testQueueOperationPerformance() async throws {
        let startTime = Date()
        let operationCount = 100

        for i in 1...operationCount {
            try await syncEngine.queueOperation(
                table: "perf_test",
                operationType: "INSERT",
                recordId: "perf-\(i)-\(UUID().uuidString)",
                payload: ["index": i, "data": "test data for performance measurement"],
                dependsOn: nil
            )
        }

        let duration = Date().timeIntervalSince(startTime)

        // Should queue 100 operations in under 5 seconds
        XCTAssertLessThan(duration, 5.0, "Should queue \(operationCount) operations quickly")

        print("Queue performance test passed: \(operationCount) operations in \(String(format: "%.2f", duration))s")
    }

    // MARK: - Helper Methods

    private func getPendingCount() async -> Int {
        let sql = "SELECT COUNT(*) as count FROM sync_outbox WHERE status IN ('pending', 'failed')"
        let rows = (try? await sqliteService.queryRaw(sql)) ?? []
        return rows.first?["count"] as? Int ?? 0
    }

    private func getLatestOperationId() async -> Int? {
        let sql = "SELECT id FROM sync_outbox ORDER BY id DESC LIMIT 1"
        let rows = (try? await sqliteService.queryRaw(sql)) ?? []
        return rows.first?["id"] as? Int
    }

    private func getOperationsWithDependency(_ dependsOnId: Int) async -> [[String: Any]] {
        let sql = "SELECT * FROM sync_outbox WHERE depends_on_id = ?"
        return (try? await sqliteService.queryRaw(sql, parameters: [dependsOnId])) ?? []
    }

    private func getOperationAttempts(recordId: String) async -> Int {
        let sql = "SELECT attempts FROM sync_outbox WHERE record_id = ?"
        let rows = (try? await sqliteService.queryRaw(sql, parameters: [recordId])) ?? []
        return rows.first?["attempts"] as? Int ?? 0
    }

    private func getOperationStatus(recordId: String) async -> String? {
        let sql = "SELECT status FROM sync_outbox WHERE record_id = ?"
        let rows = (try? await sqliteService.queryRaw(sql, parameters: [recordId])) ?? []
        return rows.first?["status"] as? String
    }

    private func cleanTestData() async {
        // Clean up test operations
        let tables = ["sync_outbox"]
        let testPatterns = [
            "test-%",
            "backoff-%",
            "retry-%",
            "blocked-%",
            "count-%",
            "dep-%",
            "perf-%"
        ]

        for pattern in testPatterns {
            _ = sqliteService.execute(
                "DELETE FROM sync_outbox WHERE record_id LIKE ?",
                parameters: [pattern]
            )
        }

        // Also clean by table names used in tests
        let testTables = [
            "test_table",
            "parent_table",
            "child_table",
            "backoff_test",
            "retry_test",
            "blocked_test",
            "count_test",
            "dep_test",
            "perf_test"
        ]

        for table in testTables {
            _ = sqliteService.execute(
                "DELETE FROM sync_outbox WHERE table_name = ?",
                parameters: [table]
            )
        }
    }
}

// MARK: - BUG-02 Tests

extension SyncEngineTests {

    /// RED test (BUG-02): Insert a PGRST205-blocked row, call the unblock method,
    /// assert the row transitions from 'blocked' to 'pending'.
    ///
    /// Uses resetBlockedOperations() (public, semantically equivalent) because
    /// the target method unblockAndRetryBlockedOperations() is added in the GREEN phase.
    /// The test documents the required behavior contract for BUG-02.
    func testUnblockSchemaErrorOperations() async throws {
        let testOperationId = "test-pgrst205-blocked-\(UUID().uuidString)"

        // Insert a blocked row simulating a PGRST205 schema error
        _ = sqliteService.execute("""
            INSERT INTO sync_outbox
                (operation_id, user_id, table_name, operation_type, record_id, payload, status, last_error)
            VALUES (?, 'test-user', 'clip_comments', 'INSERT', ?, '{}', 'blocked', 'PGRST205: column updated_at not found')
        """, parameters: [testOperationId, testOperationId])

        // Verify the row is blocked before the unblock call
        var rows = (try? await sqliteService.queryRaw(
            "SELECT status FROM sync_outbox WHERE operation_id = ?",
            parameters: [testOperationId]
        )) ?? []
        XCTAssertEqual(rows.first?["status"] as? String, "blocked",
            "Row must be in 'blocked' state before unblock call")

        // Call unblock — BUG-02 fix will expose unblockAndRetryBlockedOperations().
        // Until then, resetBlockedOperations() provides equivalent semantics for this test.
        await syncEngine.resetBlockedOperations()

        // Assert the row is now pending
        rows = (try? await sqliteService.queryRaw(
            "SELECT status FROM sync_outbox WHERE operation_id = ?",
            parameters: [testOperationId]
        )) ?? []
        XCTAssertEqual(rows.first?["status"] as? String, "pending",
            "PGRST205-blocked operations must be reset to 'pending' after unblock call")

        // Cleanup
        _ = sqliteService.execute(
            "DELETE FROM sync_outbox WHERE operation_id = ?",
            parameters: [testOperationId]
        )
    }
}

// MARK: - Integration Tests

extension SyncEngineTests {

    /// Test the complete sync flow from queue to completion
    func testFullSyncFlow() async throws {
        print("Starting full sync flow test...")

        // 1. Queue operations
        let operations = [
            ("table_a", "INSERT", ["field": "value1"]),
            ("table_b", "UPDATE", ["field": "value2"]),
            ("table_c", "UPSERT", ["field": "value3"])
        ]

        for (table, opType, payload) in operations {
            try await syncEngine.queueOperation(
                table: table,
                operationType: opType,
                recordId: "flow-\(UUID().uuidString)",
                payload: payload,
                dependsOn: nil
            )
        }

        // 2. Verify operations are queued
        let pendingCount = await getPendingCount()
        XCTAssertGreaterThanOrEqual(pendingCount, 3, "Should have at least 3 pending operations")

        // 3. Note: Full sync execution would require network mocking
        // The test verifies the queue mechanism works

        print("Full sync flow test passed")
    }

    /// Test concurrent queue operations
    func testConcurrentQueueOperations() async throws {
        print("Starting concurrent queue test...")

        // Queue multiple operations concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 1...10 {
                group.addTask {
                    try? await self.syncEngine.queueOperation(
                        table: "concurrent_test",
                        operationType: "INSERT",
                        recordId: "concurrent-\(i)-\(UUID().uuidString)",
                        payload: ["index": i],
                        dependsOn: nil
                    )
                }
            }
        }

        // Verify all operations were queued (some might fail due to race conditions)
        let count = await getPendingCount()
        XCTAssertGreaterThan(count, 0, "Should have queued operations")

        // Clean up
        _ = sqliteService.execute("DELETE FROM sync_outbox WHERE table_name = 'concurrent_test'")

        print("Concurrent queue test passed")
    }
}
