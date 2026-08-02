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

    /// Sign-out wipes the local store through resetDatabase() so the next account on this
    /// device cannot read the previous one's rows. If this stops clearing, the data-bleed
    /// returns silently.
    func testResetDatabaseClearsUserRows() async throws {
        let id = "writepath-\(UUID().uuidString)"
        try await service.upsert(table: "profiles", rows: [["id": id, "display_name": "previous user"]])

        service.resetDatabase()

        let rows = try await service.queryRaw("SELECT id FROM profiles WHERE id = ?", parameters: [id])
        XCTAssertTrue(rows.isEmpty, "resetDatabase must leave no rows from the previous account")
    }

    /// resetDatabase() closes and reopens both connections, so the writer has to come back
    /// usable — otherwise the account signing in after a sign-out would silently persist nothing.
    func testWritesStillPersistAfterResetDatabase() async throws {
        service.resetDatabase()

        let id = "writepath-\(UUID().uuidString)"
        try await service.upsert(table: "profiles", rows: [["id": id, "display_name": "next user"]])

        let rows = try await service.queryRaw(
            "SELECT display_name FROM profiles WHERE id = ?", parameters: [id]
        )
        XCTAssertEqual(rows.first?["display_name"] as? String, "next user",
            "the writer connection must still work after resetDatabase")
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

    /// When a transient local core-list id is reconciled with the canonical id, a duplicate
    /// natural key must not make the UPDATE fail and the subsequent list DELETE cascade away
    /// the other, unique items from the transient list.
    func testCoreListIdentityMergePreservesUniqueItemsWhenOneItemCollides() async throws {
        let userId = "list-merge-user-\(UUID().uuidString)"
        let canonicalId = "canonical-\(UUID().uuidString)"
        let transientId = "transient-\(UUID().uuidString)"

        try await service.upsert(table: "profiles", rows: [["id": userId]])
        try await service.upsert(table: "lists", rows: [[
            "id": canonicalId, "user_id": userId, "name": "Watchlist", "type": "watchlist"
        ]])
        // `upsert` marks pulled rows as synced by design; this fixture specifically represents a
        // local-only list, so insert it through the raw write path and leave synced_at NULL.
        try await service.executeWrite(
            "INSERT INTO lists (id, user_id, name, type) VALUES (?, ?, ?, ?)",
            parameters: [transientId, userId, "Local", "custom"]
        )
        try await service.upsert(table: "list_items", rows: [
            [
                "id": "canonical-duplicate-\(UUID().uuidString)",
                "list_id": canonicalId,
                "user_id": userId,
                "media_id": 101,
                "media_type": "movie",
                "title": "Already canonical"
            ],
            [
                "id": "transient-duplicate-\(UUID().uuidString)",
                "list_id": transientId,
                "user_id": userId,
                "media_id": 101,
                "media_type": "movie",
                "title": "Same natural key"
            ],
            [
                "id": "transient-unique-\(UUID().uuidString)",
                "list_id": transientId,
                "user_id": userId,
                "media_id": 202,
                "media_type": "movie",
                "title": "Must survive"
            ]
        ])

        try ListManager.mergeUnsyncedLocalList(
            from: transientId,
            into: canonicalId,
            db: service
        )

        let canonicalItems = try await service.queryRaw(
            "SELECT media_id FROM list_items WHERE list_id = ? ORDER BY media_id",
            parameters: [canonicalId]
        )
        let transientLists = try await service.queryRaw(
            "SELECT id FROM lists WHERE id = ?",
            parameters: [transientId]
        )

        XCTAssertEqual(canonicalItems.compactMap { $0["media_id"] as? Int }, [101, 202])
        XCTAssertTrue(transientLists.isEmpty, "the transient local list should be removed only after its items converge")
    }

    // MARK: - STAB-002: transaction atomicity

    /// A transaction that throws part-way must leave NO rows behind. The old async transaction()
    /// issued BEGIN/COMMIT on separate writerQueue hops, so its ROLLBACK didn't reliably undo the
    /// body's writes. The synchronous single-block version must roll back cleanly.
    func testTransactionRollsBackOnThrow() async throws {
        let idA = "txn-\(UUID().uuidString)"
        let idB = "txn-\(UUID().uuidString)"

        struct Boom: Error {}
        XCTAssertThrowsError(
            try service.transaction { txn in
                try txn.insert("profiles", values: ["id": idA, "display_name": "a"])
                try txn.insert("profiles", values: ["id": idB, "display_name": "b"])
                throw Boom()   // after two successful inserts
            }
        )

        let rows = try await service.queryRaw(
            "SELECT id FROM profiles WHERE id IN (?, ?)", parameters: [idA, idB]
        )
        XCTAssertEqual(rows.count, 0, "a thrown transaction must roll back every write it made")
    }

    /// A transaction that completes must persist all of its writes atomically.
    func testTransactionCommitsAllWrites() async throws {
        let idA = "txn-\(UUID().uuidString)"
        let idB = "txn-\(UUID().uuidString)"

        try service.transaction { txn in
            try txn.insert("profiles", values: ["id": idA, "display_name": "a"])
            try txn.insert("profiles", values: ["id": idB, "display_name": "b"])
        }

        let rows = try await service.queryRaw(
            "SELECT id FROM profiles WHERE id IN (?, ?)", parameters: [idA, idB]
        )
        XCTAssertEqual(rows.count, 2, "a completed transaction must commit all of its writes")
    }

    /// A failing statement inside the transaction propagates and rolls back the earlier ones.
    func testTransactionRollsBackOnStatementError() async throws {
        let idA = "txn-\(UUID().uuidString)"

        XCTAssertThrowsError(
            try service.transaction { txn in
                try txn.insert("profiles", values: ["id": idA, "display_name": "a"])
                // Invalid table → txn.execute throws, aborting the transaction.
                try txn.execute("INSERT INTO no_such_table (id) VALUES (?)", parameters: ["x"])
            }
        )

        let rows = try await service.queryRaw(
            "SELECT id FROM profiles WHERE id = ?", parameters: [idA]
        )
        XCTAssertEqual(rows.count, 0, "the earlier insert must be undone when a later statement fails")
    }
}
