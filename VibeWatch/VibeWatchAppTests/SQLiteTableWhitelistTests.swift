import XCTest
@testable import VibeWatchApp

/// P1 (SPEC v3): the `SQLiteTable` whitelist gates every dynamic-SQL call on the generic CRUD
/// layer (`insert`/`update`/`upsert`/`delete`/`select`/`count`). A table that exists in SQLite but
/// is missing from the enum makes each of those calls throw `invalidTableName` — and every call
/// site swallows it under `try?`, so the write simply disappears.
///
/// That is not hypothetical: `watch_providers` was created by migration 5 and never whitelisted,
/// so the entire provider cache was a no-op from the day it shipped. SPEC v3 adds six more local
/// tables; without this test each of them can repeat the same failure invisibly.
@MainActor
final class SQLiteTableWhitelistTests: XCTestCase {

    private var service: SQLiteService!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "vibewatch_whitelist_\(UUID().uuidString).sqlite"
        service = SQLiteService(dbPath: dbPath)
    }

    override func tearDown() async throws {
        SQLiteService.trapsOnUnknownTable = true
        service = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    /// Every table the schema + migrations actually create must be writable through the CRUD layer.
    func testEveryCreatedTableIsWhitelisted() async throws {
        let created = try await createdTableNames()

        XCTAssertFalse(created.isEmpty, "the fresh database should have tables")

        let notWhitelisted = created.subtracting(SQLiteTable.validTableNames).sorted()
        XCTAssertTrue(
            notWhitelisted.isEmpty,
            "these tables exist in SQLite but are missing from SQLiteTable, so every write to them "
            + "throws and is swallowed: \(notWhitelisted.joined(separator: ", "))"
        )
    }

    /// The reverse direction: an enum entry naming a table nobody creates is a typo waiting to
    /// produce "no such table" at runtime instead of the compile-time safety the enum promises.
    func testEveryWhitelistedTableExists() async throws {
        let created = try await createdTableNames()

        let missing = SQLiteTable.validTableNames.subtracting(created).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "these tables are whitelisted but never created: \(missing.joined(separator: ", "))"
        )
    }

    /// The failure must be loud. A write to a table that exists in SQLite but not in the enum
    /// throws rather than reporting success.
    func testWriteToNonWhitelistedTableThrows() async throws {
        SQLiteService.trapsOnUnknownTable = false   // debug builds trap otherwise — that is the point

        service.execute("CREATE TABLE IF NOT EXISTS rogue_table (id TEXT PRIMARY KEY)")

        do {
            _ = try await service.insert("rogue_table", values: ["id": "x"])
            XCTFail("a write to a non-whitelisted table must throw, not silently do nothing")
        } catch SQLiteError.invalidTableName(let name) {
            XCTAssertEqual(name, "rogue_table")
        }
    }

    /// The concrete regression: watch providers now reach the local cache.
    func testWatchProvidersWritePersists() async throws {
        let id = "603-movie-IT"
        _ = try await service.insert("watch_providers", values: [
            "id": id,
            "media_id": 603,
            "media_type": "movie",
            "region": "IT",
            "providers_json": "e30=",
            "refreshed_at": "2026-07-30T00:00:00Z",
            "expires_at": "2026-07-31T00:00:00Z"
        ])

        let rows = try await service.queryRaw(
            "SELECT region FROM watch_providers WHERE id = ?", parameters: [id]
        )
        XCTAssertEqual(rows.first?["region"] as? String, "IT",
            "watch_providers must be writable through the whitelisted CRUD layer")
    }

    // MARK: - Helpers

    /// Table names present in the freshly created database, minus SQLite's own bookkeeping and the
    /// scratch tables migration 6 creates and drops within a single run.
    private func createdTableNames() async throws -> Set<String> {
        let rows = try await service.queryRaw("""
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        """)
        return Set(rows.compactMap { $0["name"] as? String })
    }
}
