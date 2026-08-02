import XCTest
@testable import VibeWatchApp

/// Unit tests for the paginated pull walk (SPEC v3 §5, blocco 4).
///
/// The walk is exercised against a fake table instead of Supabase: the interesting behaviour is
/// where the loop stops and how far it advances, and both are decided by the client.
final class SyncPaginationTests: XCTestCase {

    // MARK: - Helpers

    /// A stand-in remote table of `count` rows, answering a window like PostgREST does.
    ///
    /// `serverMaxRows` mimics `db-max-rows`: the server never returns more than that in one
    /// response, regardless of the limit asked for.
    private final class FakeTable {
        let rows: [[String: Any]]
        let serverMaxRows: Int
        private(set) var windows: [(offset: Int, limit: Int)] = []

        init(count: Int, serverMaxRows: Int = .max) {
            self.rows = (0..<count).map { ["id": "row-\($0)"] }
            self.serverMaxRows = serverMaxRows
        }

        func page(offset: Int, limit: Int) -> [[String: Any]] {
            windows.append((offset, limit))
            guard offset < rows.count else { return [] }
            let capped = min(limit, serverMaxRows)
            let end = min(offset + capped, rows.count)
            return Array(rows[offset..<end])
        }
    }

    /// Runs a walk over a fake table and returns everything that came out of it.
    private func walk(
        _ table: FakeTable,
        pageSize: Int = 1_000,
        maxPages: Int = SyncPagination.defaultMaxPages
    ) async throws -> (total: Int, seen: [String], pages: Int) {
        var seen: [String] = []
        var pages = 0

        let total = try await SyncPagination.walk(
            table: "fake",
            pageSize: pageSize,
            maxPages: maxPages,
            fetchPage: { offset, limit in table.page(offset: offset, limit: limit) },
            handlePage: { rows in
                pages += 1
                seen.append(contentsOf: rows.compactMap { $0["id"] as? String })
            }
        )

        return (total, seen, pages)
    }

    // MARK: - Termination

    func testEmptyTableWalksNothing() async throws {
        let table = FakeTable(count: 0)
        let result = try await walk(table)

        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(result.pages, 0, "an empty page must not be handed to handlePage")
    }

    func testSinglePartialPage() async throws {
        let table = FakeTable(count: 3)
        let result = try await walk(table)

        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(result.seen, ["row-0", "row-1", "row-2"])
    }

    /// A table whose size is an exact multiple of the page size needs one extra request to learn
    /// that it is finished. Off-by-one here would silently drop the last page.
    func testExactMultipleOfPageSize() async throws {
        let table = FakeTable(count: 2_000)
        let result = try await walk(table, pageSize: 1_000)

        XCTAssertEqual(result.total, 2_000)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(Set(result.seen).count, 2_000, "no row may be walked twice")
        XCTAssertEqual(table.windows.count, 3, "the final empty request is what ends the walk")
    }

    // MARK: - Windows

    func testWindowsAreContiguousAndDoNotOverlap() async throws {
        let table = FakeTable(count: 2_500)
        _ = try await walk(table, pageSize: 1_000)

        XCTAssertEqual(table.windows.map(\.offset), [0, 1_000, 2_000, 2_500])
        XCTAssertTrue(table.windows.allSatisfy { $0.limit == 1_000 })
    }

    // MARK: - The regression this block exists for

    /// The TV Time import: 20.000 events for one user. Before pagination the pull issued one
    /// unbounded request and kept whatever came back.
    func testTwentyThousandRowsAreAllWalked() async throws {
        let table = FakeTable(count: 20_000)
        let result = try await walk(table, pageSize: 1_000)

        XCTAssertEqual(result.total, 20_000)
        XCTAssertEqual(result.pages, 20)
        XCTAssertEqual(Set(result.seen).count, 20_000, "every event must arrive exactly once")
        XCTAssertEqual(result.seen.first, "row-0")
        XCTAssertEqual(result.seen.last, "row-19999")
    }

    /// A server capping responses below the requested page size must not truncate the walk.
    ///
    /// This is why the loop advances by the rows actually returned and stops only on an empty
    /// page: advancing by the requested limit would skip the 500 rows withheld on every page, and
    /// stopping on a short page would end the walk after the first one.
    func testServerCapBelowPageSizeStillWalksEverything() async throws {
        let table = FakeTable(count: 5_000, serverMaxRows: 500)
        let result = try await walk(table, pageSize: 1_000)

        XCTAssertEqual(result.total, 5_000, "a short page is not the end of the table")
        XCTAssertEqual(Set(result.seen).count, 5_000)
        XCTAssertEqual(result.pages, 10, "500 rows at a time")
    }

    // MARK: - Ceiling

    func testExceedingMaxPagesThrowsInsteadOfTruncating() async throws {
        let table = FakeTable(count: 10_000)

        do {
            _ = try await walk(table, pageSize: 1_000, maxPages: 3)
            XCTFail("the walk must fail loudly rather than return a truncated table")
        } catch let error as SyncPagination.PageLimitExceeded {
            XCTAssertEqual(error.table, "fake")
            XCTAssertEqual(error.pagesWalked, 3)
            XCTAssertEqual(error.rowsSeen, 3_000)
        }
    }

    func testNonPositivePageSizeDoesNotSpin() async throws {
        let table = FakeTable(count: 10)
        let result = try await walk(table, pageSize: 0, maxPages: 50)

        XCTAssertEqual(result.total, 10, "a page size of 0 is clamped to 1 rather than looping forever")
    }
}
