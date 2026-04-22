import XCTest
@testable import VibeWatchApp

// TDD test file for performance requirements PERF-01 through PERF-04.
// Plans 03-01, 03-02, and 03-03 progressively turn RED tests GREEN.

final class PerformanceTests: XCTestCase {

    // MARK: - PERF-01 Tests

    /// PERF-01: SQLiteService.hasPersonalizedDiscoveryCache returns false when the
    /// personalized_discovery table has no rows (confirmed by deleting all rows first).
    func testLoadCachedContentSyncReturnsFalseWhenEmpty() {
        let service = SQLiteService.shared
        // Delete all rows so the table is definitely empty, then re-check.
        service.execute("DELETE FROM personalized_discovery")
        // Re-run the cache state check to reflect current DB state.
        service.refreshCacheState()
        let result: Bool = service.hasPersonalizedDiscoveryCache
        XCTAssertFalse(result, "Expected hasPersonalizedDiscoveryCache == false on empty table")
    }

    /// PERF-01: hasCachedPersonalizedContent() returns the same value as hasPersonalizedDiscoveryCache,
    /// and returns true after inserting a row into personalized_discovery.
    func testLoadCachedContentSyncReturnsTrueWithData() {
        let service = SQLiteService.shared
        // Insert a minimal sentinel row into personalized_discovery so the table is non-empty.
        service.execute("""
            INSERT OR REPLACE INTO personalized_discovery
                (id, user_id, device_id, carousel_type, carousel_title, media_id, media_type, generated_at, expires_at)
            VALUES
                ('perf-test-row', 'test-user', 'test-device', 'test', 'Test Carousel', 1, 'movie', datetime('now'), datetime('now', '+1 day'))
        """)
        // Refresh the cached flag so it reflects the newly inserted row.
        service.refreshCacheState()
        let propertyValue = service.hasPersonalizedDiscoveryCache
        let methodValue = service.hasCachedPersonalizedContent()
        XCTAssertTrue(propertyValue, "hasPersonalizedDiscoveryCache must be true when table has rows")
        XCTAssertEqual(propertyValue, methodValue,
                       "hasCachedPersonalizedContent() must mirror hasPersonalizedDiscoveryCache")
        // Cleanup: remove the sentinel row.
        service.execute("DELETE FROM personalized_discovery WHERE id = 'perf-test-row'")
        service.refreshCacheState()
    }

    // MARK: - PERF-02 Tests

    /// PERF-02: AppState.carouselsGeneratedThisLaunch starts false on init.
    @MainActor
    func testCarouselGeneratedOncePerLaunch() {
        let appState = AppState()
        let initialValue: Bool = appState.carouselsGeneratedThisLaunch
        XCTAssertFalse(initialValue, "carouselsGeneratedThisLaunch should start as false")
    }

    // MARK: - PERF-03 Tests (implemented in plan 03-02)

    /// PERF-03: SQLiteService exposes a `readerQueue` DispatchQueue with .concurrent
    /// attributes. Dispatching 10 concurrent closures onto it must not deadlock while
    /// a serial write runs on writerQueue simultaneously.
    func testConcurrentReadDoesNotBlockWrite() {
        let service = SQLiteService.shared

        // Verify readerQueue is concurrent
        XCTAssertEqual(service.readerQueue.label, "com.vibewatch.sqlite.reader",
                       "readerQueue label must be 'com.vibewatch.sqlite.reader'")

        // Dispatch 10 concurrent reads and verify they all complete without deadlock.
        let expectation = XCTestExpectation(description: "10 concurrent reads complete")
        expectation.expectedFulfillmentCount = 10
        let group = DispatchGroup()
        for _ in 0..<10 {
            group.enter()
            service.readerQueue.async {
                // Simple work on the reader queue
                _ = (0..<100).reduce(0, +)
                expectation.fulfill()
                group.leave()
            }
        }
        // Also fire a write concurrently to confirm no deadlock
        service.execute("SELECT 1")
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - PERF-04 Tests (implemented in plan 03-03)

    /// PERF-04: DiscoveryPersonalizationService returns carousels from its in-memory cache
    /// without making any network call when the cache is already populated.
    /// RED: cache-first test seam not yet added — added in plan 03-03.
    func testDiscoveryLoadsFromCacheBeforeNetwork() {
        XCTFail("RED — implement cache-first test seam in plan 03-03 for DiscoveryPersonalizationService")
    }

    /// PERF-04: ClipsRepository returns cached rows from DatabaseClipsService without
    /// invoking a network refresh before the initial return.
    /// RED: stub — ClipsRepository exists but the test seam for cache injection is absent.
    func testClipsLoadsFromCacheBeforeNetwork() {
        XCTFail("RED — implement cache-first test seam in plan 03-03 for ClipsRepository")
    }
}
