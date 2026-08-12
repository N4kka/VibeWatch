import Foundation

// MARK: - SyncPagination

/// Walks a remote table one page at a time during pull.
///
/// `STAB-008` had been closed "by measurement": no user exceeded 419 rows, so the unpaginated
/// `SELECT *` in the pull looked harmless. A single user imported from TV Time brings 20.000
/// `watch_events`, and one unbounded request for them fails in one of two ways.
///
/// On this project (checked 2026-07-31) `pgrst.db_max_rows` is *not* set, so the live failure is
/// the `statement_timeout = 8s` on the `authenticated` role: the request dies and the whole table
/// fails to pull, loudly but repeatedly. If a `db-max-rows` were ever configured, the same request
/// would instead come back truncated with no indication of it, and the client would mirror a
/// partial table into SQLite as if it were complete — the same class of silent data loss as P1,
/// one layer up. Paging fixes both: every request is small and bounded.
///
/// The walk is a free function over a `fetchPage` closure rather than a method on `SyncEngine`
/// so the termination rules can be tested without a network or a live Supabase project.
public enum SyncPagination {

    /// Rows requested per page. The spec fixes this at 1.000.
    public static let defaultPageSize = 1_000

    /// Hard ceiling on the number of pages for one table, so a server that keeps answering can
    /// never spin the loop forever. At the default page size this is a million rows, far above
    /// any realistic import.
    public static let defaultMaxPages = 1_000

    /// Raised when a table is still producing rows after `maxPages`.
    ///
    /// Deliberately an error rather than a quiet `break`: stopping silently at the ceiling would
    /// truncate the table, which is the exact failure this type exists to prevent. Failing loudly
    /// makes the pull for that table fail, get logged, and be retried.
    public struct PageLimitExceeded: Error, LocalizedError, Equatable {
        public let table: String
        public let pagesWalked: Int
        public let rowsSeen: Int

        public var errorDescription: String? {
            "Pull of \(table) exceeded \(pagesWalked) pages (\(rowsSeen) rows) and was stopped."
        }
    }

    /// Fetches every row of a table, a page at a time, handing each page to `handlePage`.
    ///
    /// Pages are handled as they arrive instead of being accumulated and returned: 20.000 rows of
    /// `watch_events` held as `[[String: Any]]` before a single bulk upsert is a memory spike on
    /// an old phone for no benefit, since each page can be resolved and written on its own.
    ///
    /// - Parameters:
    ///   - table: Table name, used only for diagnostics.
    ///   - pageSize: Rows to request per page.
    ///   - maxPages: Ceiling before `PageLimitExceeded` is thrown.
    ///   - fetchPage: Returns the rows in the inclusive window `[offset, offset + limit - 1]`.
    ///   - handlePage: Consumes one non-empty page.
    /// - Returns: The total number of rows walked.
    @discardableResult
    public static func walk(
        table: String,
        pageSize: Int = defaultPageSize,
        maxPages: Int = defaultMaxPages,
        fetchPage: (_ offset: Int, _ limit: Int) async throws -> [[String: Any]],
        handlePage: (_ rows: [[String: Any]]) async throws -> Void
    ) async throws -> Int {
        // A non-positive page size would ask for an empty window forever.
        let limit = max(1, pageSize)

        var offset = 0
        var pages = 0

        while true {
            let rows = try await fetchPage(offset, limit)

            // An empty page is the only termination signal that is always true. A short page is
            // not: PostgREST caps a response at `db-max-rows`, so a server configured below our
            // page size answers every request short while still having rows left. Stopping on
            // `rows.count < limit` would drop everything past the first page on such a project.
            if rows.isEmpty {
                return offset
            }

            try await handlePage(rows)

            // Advance by what actually arrived, not by `limit`, for the same reason: with a
            // server cap of 500 against a page size of 1.000, advancing by 1.000 would skip the
            // 500 rows the server withheld on every single page.
            offset += rows.count
            pages += 1

            if pages >= maxPages {
                throw PageLimitExceeded(table: table, pagesWalked: pages, rowsSeen: offset)
            }
        }
    }
}
