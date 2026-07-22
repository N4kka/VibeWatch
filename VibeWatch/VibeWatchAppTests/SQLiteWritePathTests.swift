import XCTest
@testable import VibeWatchApp

/// Regression guard for the read-only write path.
///
/// `SQLiteService` keeps two connections: a writer (`db`) and a reader (`readerDb`) opened
/// `SQLITE_OPEN_READONLY`. `queryRaw` runs on the reader, so any write routed through it
/// prepared successfully but stepped to `SQLITE_READONLY` — a code the row loop treated as
/// "no more rows" rather than an error. The write vanished with no throw and no log, and
/// `upsert`/`update`/`delete` all went through that path, so the entire generic CRUD layer
/// was a silent no-op (notably on the pull-sync path in SupabaseClient).
///
/// These tests assert persistence by reading the data back, which is the only way to catch a
/// failure mode that produces no error signal.
@MainActor
final class SQLiteWritePathTests: XCTestCase {

    private var service: SQLiteService!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "vibewatch_writepath_\(UUID().uuidString).sqlite"
        service = SQLiteService(dbPath: dbPath)
    }

    override func tearDown() async throws {
        service = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    /// The core regression: an upsert must survive a read-back.
    func testUpsertActuallyPersists() async throws {
        let id = "writepath-\(UUID().uuidString)"
        try await service.upsert(table: "profiles", rows: [[
            "id": id,
            "display_name": "persisted"
        ]])

        let rows = try await service.queryRaw(
            "SELECT display_name FROM profiles WHERE id = ?", parameters: [id]
        )
        XCTAssertEqual(rows.count, 1, "upsert must write a row that is readable afterwards")
        XCTAssertEqual(rows.first?["display_name"] as? String, "persisted")
    }

    /// An upsert on an existing primary key must replace it, not silently do nothing.
    func testUpsertReplacesExistingRow() async throws {
        let id = "writepath-\(UUID().uuidString)"
        try await service.upsert(table: "profiles", rows: [["id": id, "display_name": "first"]])
        try await service.upsert(table: "profiles", rows: [["id": id, "display_name": "second"]])

        let rows = try await service.queryRaw(
            "SELECT display_name FROM profiles WHERE id = ?", parameters: [id]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["display_name"] as? String, "second",
            "a second upsert on the same id must overwrite the row")
    }

    func testUpdatePersists() async throws {
        let id = "writepath-\(UUID().uuidString)"
        try await service.upsert(table: "profiles", rows: [["id": id, "display_name": "before"]])
        try await service.update("profiles", values: ["display_name": "after"],
                                 where: "id = ?", parameters: [id])

        let rows = try await service.queryRaw(
            "SELECT display_name FROM profiles WHERE id = ?", parameters: [id]
        )
        XCTAssertEqual(rows.first?["display_name"] as? String, "after")
    }

    func testHardDeletePersists() async throws {
        let id = "writepath-\(UUID().uuidString)"
        try await service.upsert(table: "profiles", rows: [["id": id, "display_name": "doomed"]])
        try await service.delete("profiles", where: "id = ?", parameters: [id], hard: true)

        let rows = try await service.queryRaw(
            "SELECT id FROM profiles WHERE id = ?", parameters: [id]
        )
        XCTAssertTrue(rows.isEmpty, "a hard delete must remove the row")
    }

    /// A write handed to `queryRaw` is rerouted to the writer connection rather than dropped,
    /// so call sites that were never migrated still persist their data.
    func testWriteThroughQueryRawIsReroutedNotDropped() async throws {
        let id = "writepath-\(UUID().uuidString)"
        _ = try await service.queryRaw(
            "REPLACE INTO profiles (id, display_name) VALUES (?, ?)",
            parameters: [id, "via-queryRaw"]
        )

        let rows = try await service.queryRaw(
            "SELECT display_name FROM profiles WHERE id = ?", parameters: [id]
        )
        XCTAssertEqual(rows.first?["display_name"] as? String, "via-queryRaw",
            "queryRaw must reroute writes to the writer connection instead of swallowing them")
    }

    /// A genuinely broken write must throw rather than resolve as an empty result set.
    func testFailingWriteThrows() async {
        do {
            try await service.executeWrite("REPLACE INTO no_such_table (id) VALUES (?)",
                                           parameters: ["x"])
            XCTFail("executeWrite must throw when the statement cannot be prepared")
        } catch {
            // expected
        }
    }
}
