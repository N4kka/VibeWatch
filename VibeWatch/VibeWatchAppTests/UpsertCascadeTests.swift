import XCTest
@testable import VibeWatchApp

/// Regression guard for the cascading-delete data loss in the generic upsert.
///
/// `upsert` used to emit `REPLACE INTO`, which is not an upsert: on a constraint violation it
/// DELETEs the conflicting row before inserting the new one. `openDatabase()` sets
/// `PRAGMA foreign_keys = ON`, so that delete runs the `ON DELETE CASCADE` actions — and 21 tables
/// cascade from `profiles(id)`, `list_items` cascades from `lists(id)`.
///
/// `SyncEngine.pullFromRemoteInternal` upserts `profiles` first on every single sync, so one
/// `REPLACE INTO profiles` wiped the whole user-scoped local database. The pull then refilled the
/// 13 tables it knows about and left the rest empty. This is the mechanism behind the reported
/// "on the second launch the list shows 1 item instead of 141".
///
/// Every test here writes a parent row *that already exists* — the case the previous
/// `SQLiteWritePathTests` never covered, because it upserted `profiles` with no children.
@MainActor
final class UpsertCascadeTests: XCTestCase {

    private var service: SQLiteService!
    private var dbPath: String!
    private var userId: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "vibewatch_cascade_\(UUID().uuidString).sqlite"
        service = SQLiteService(dbPath: dbPath)
        userId = "user-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        service = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    /// Builds a user with one list and `count` items in it.
    private func seedList(itemCount: Int) async throws -> String {
        let listId = "list-\(UUID().uuidString)"

        try await service.upsert(table: "profiles", rows: [[
            "id": userId!, "email": "\(userId!)@example.com", "display_name": "Nicola"
        ]])
        try await service.upsert(table: "lists", rows: [[
            "id": listId, "user_id": userId!, "name": "Watchlist", "type": "watchlist"
        ]])
        try await service.upsert(table: "list_items", rows: (1...itemCount).map { i in
            [
                "id": "item-\(i)-\(listId)",
                "list_id": listId,
                "user_id": userId!,
                "media_id": i,
                "media_type": "movie",
                "title": "Film \(i)"
            ]
        })

        try await assertItemCount(itemCount, listId: listId, message: "seed")
        return listId
    }

    private func itemCount(listId: String) async throws -> Int {
        let rows = try await service.queryRaw(
            "SELECT COUNT(*) AS n FROM list_items WHERE list_id = ?", parameters: [listId]
        )
        return rows.first?["n"] as? Int ?? -1
    }

    private func assertItemCount(
        _ expected: Int, listId: String, message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actual = try await itemCount(listId: listId)
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    /// The headline case: re-upserting the profile row is the first thing every pull does.
    func testUpsertingExistingProfileKeepsTheUsersData() async throws {
        let listId = try await seedList(itemCount: 141)

        // Exactly what pullTableWithConflictResolution does for "profiles".
        try await service.upsert(table: "profiles", rows: [[
            "id": userId!, "email": "\(userId!)@example.com", "display_name": "Nicola"
        ]])

        try await assertItemCount(141, listId: listId,
            message: "re-upserting profiles must not cascade-delete the user's list items")

        let lists = try await service.queryRaw(
            "SELECT COUNT(*) AS n FROM lists WHERE user_id = ?", parameters: [userId!]
        )
        XCTAssertEqual(lists.first?["n"] as? Int, 1,
            "re-upserting profiles must not cascade-delete the user's lists")
    }

    /// Same mechanism one level down: `lists` is pulled before `list_items`.
    func testUpsertingExistingListKeepsItsItems() async throws {
        let listId = try await seedList(itemCount: 141)

        try await service.upsert(table: "lists", rows: [[
            "id": listId, "user_id": userId!, "name": "Watchlist", "type": "watchlist"
        ]])

        try await assertItemCount(141, listId: listId,
            message: "re-upserting a list must not cascade-delete its items")
    }

    /// An upsert still has to update, not just avoid deleting.
    func testUpsertOnExistingParentStillAppliesTheNewValues() async throws {
        let listId = try await seedList(itemCount: 3)

        try await service.upsert(table: "lists", rows: [[
            "id": listId, "user_id": userId!, "name": "Da vedere", "type": "watchlist"
        ]])

        let rows = try await service.queryRaw(
            "SELECT name FROM lists WHERE id = ?", parameters: [listId]
        )
        XCTAssertEqual(rows.first?["name"] as? String, "Da vedere")
        try await assertItemCount(3, listId: listId, message: "update must not drop items either")
    }

    /// A remote row carrying a new id but the same natural key must converge onto the existing
    /// row rather than raise — this is the one useful thing REPLACE was doing.
    func testUpsertConvergesOnNaturalKeyCollision() async throws {
        let listId = try await seedList(itemCount: 1)

        try await service.upsert(table: "list_items", rows: [[
            "id": "different-id-\(UUID().uuidString)",
            "list_id": listId,
            "user_id": userId!,
            "media_id": 1,
            "media_type": "movie",
            "title": "Film 1 (rinominato)"
        ]])

        try await assertItemCount(1, listId: listId,
            message: "a natural-key collision must update in place, not duplicate")

        let rows = try await service.queryRaw(
            "SELECT title FROM list_items WHERE list_id = ?", parameters: [listId]
        )
        XCTAssertEqual(rows.first?["title"] as? String, "Film 1 (rinominato)")
    }

    /// The tables the pull does *not* refill afterwards are the ones that were lost for good.
    func testUpsertingExistingProfileKeepsTablesThePullNeverRestores() async throws {
        _ = try await seedList(itemCount: 5)

        try await service.upsert(table: "unified_user_preferences", rows: (1...20).map { i in
            [
                "id": "pref-\(i)-\(userId!)",
                "user_id": userId!,
                "device_id": "device-1",
                "preference_category": "genre",
                "preference_id": "\(i)",
                "score": Double(i),
                "created_at": "2026-07-23T00:00:00Z",
                "updated_at": "2026-07-23T00:00:00Z"
            ]
        })

        try await service.upsert(table: "profiles", rows: [[
            "id": userId!, "display_name": "Nicola"
        ]])

        let rows = try await service.queryRaw(
            "SELECT COUNT(*) AS n FROM unified_user_preferences WHERE user_id = ?",
            parameters: [userId!]
        )
        XCTAssertEqual(rows.first?["n"] as? Int, 20,
            "unified_user_preferences is not in SyncEngine's pull list: once cascaded away it never comes back")
    }
}
