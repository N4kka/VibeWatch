import XCTest
@testable import VibeWatchApp

final class MultiDeviceSyncTests: XCTestCase {

    var resolver: ConflictResolver!

    override func setUp() {
        super.setUp()
        resolver = ConflictResolver()
    }

    override func tearDown() {
        resolver = nil
        super.tearDown()
    }

    // MARK: - Preference Weighted Merge

    func testPreferenceMergeConflict() {
        // Two devices update the same unified_user_preferences record while offline.
        // Device A has score_from_clips = 10, Device B has score_from_discovery = 15.
        let local: [String: Any] = [
            "id": "pref-878",
            "score": 10.0,
            "score_from_clips": 10.0,
            "score_from_discovery": 0.0,
            "interaction_count": 1,
            "updated_at": "2024-01-02T10:00:00Z"
        ]
        let remote: [String: Any] = [
            "id": "pref-878",
            "score": 15.0,
            "score_from_clips": 0.0,
            "score_from_discovery": 15.0,
            "interaction_count": 1,
            "updated_at": "2024-01-01T10:00:00Z"
        ]

        let result = resolver.resolve(table: "unified_user_preferences", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .weightedMerge)
        // source score fields use max() — each device's cumulative engagement is preserved
        XCTAssertEqual(result.record["score_from_clips"] as? Double, 10.0,
                       "score_from_clips should be max(10.0, 0.0) = 10.0")
        XCTAssertEqual(result.record["score_from_discovery"] as? Double, 15.0,
                       "score_from_discovery should be max(0.0, 15.0) = 15.0")
    }

    // MARK: - Watchlist Union Strategy

    func testWatchlistConflict() {
        // Two devices independently add different list_items (neither is deleted).
        // Union strategy: each item resolved independently should be kept as-is.
        let localItem: [String: Any] = [
            "id": "item-001",
            "list_id": "list-A",
            "media_id": 123,
            "updated_at": "2024-01-02T10:00:00Z"
        ]
        let remoteItem: [String: Any] = [
            "id": "item-002",
            "list_id": "list-A",
            "media_id": 456,
            "updated_at": "2024-01-01T10:00:00Z"
        ]

        let resultLocal = resolver.resolve(table: "list_items", local: localItem, remote: localItem)
        let resultRemote = resolver.resolve(table: "list_items", local: remoteItem, remote: remoteItem)

        XCTAssertEqual(resultLocal.strategyUsed, .union)
        XCTAssertEqual(resultRemote.strategyUsed, .union)
        // Neither record is deleted — both items are kept
        XCTAssertNil(resultLocal.record["deleted_at"] as? String,
                     "Non-deleted item should not have a deleted_at timestamp")
        XCTAssertNil(resultRemote.record["deleted_at"] as? String,
                     "Non-deleted item should not have a deleted_at timestamp")
    }

    func testWatchlistDeletionSemantics() {
        // Local record: deleted (deleted_at is a timestamp string)
        // Remote record: not deleted (deleted_at is NSNull)
        // ConflictResolver.union keeps non-deleted record — deletion does NOT propagate across devices
        let local: [String: Any] = [
            "id": "item-001",
            "list_id": "list-A",
            "media_id": 123,
            "deleted_at": "2024-01-02T10:00:00Z",
            "updated_at": "2024-01-02T10:00:00Z"
        ]
        let remote: [String: Any] = [
            "id": "item-001",
            "list_id": "list-A",
            "media_id": 123,
            "deleted_at": NSNull(),
            "updated_at": "2024-01-01T10:00:00Z"
        ]

        let result = resolver.resolve(table: "list_items", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .union)
        // Non-deleted remote wins — deletion is NOT propagated
        XCTAssertEqual(result.source, .remote,
                       "Non-deleted remote record should win over locally-deleted record")
    }

    // MARK: - Reaction Last-Write-Wins

    func testReactionConflict() {
        // Two devices set different reaction_type on the same movie_reactions record.
        // The record with the newer updated_at timestamp should win.
        let local: [String: Any] = [
            "id": "reaction-1",
            "reaction_type": "love",
            "updated_at": "2024-01-02T15:00:00Z"   // newer
        ]
        let remote: [String: Any] = [
            "id": "reaction-1",
            "reaction_type": "like",
            "updated_at": "2024-01-01T10:00:00Z"   // older
        ]

        let result = resolver.resolve(table: "movie_reactions", local: local, remote: remote)

        XCTAssertEqual(result.strategyUsed, .lastWriteWins)
        XCTAssertEqual(result.source, .local, "Local (newer timestamp) should win")
        XCTAssertEqual(result.record["reaction_type"] as? String, "love")
    }

    // MARK: - SyncEngine Queue

    func testSyncEngineQueueOperation() async throws {
        try await SyncEngine.shared.queueOperation(
            table: "test_table",
            operationType: "INSERT",
            recordId: UUID().uuidString,
            payload: ["key": "value"],
            dependsOn: nil
        )

        let count = await MainActor.run { SyncEngine.shared.pendingOperationsCount }
        XCTAssertGreaterThanOrEqual(count, 1,
                                    "pendingOperationsCount should be >= 1 after queuing an operation")
    }
}
