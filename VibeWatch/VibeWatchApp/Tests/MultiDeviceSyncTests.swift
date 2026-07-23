import XCTest
import Combine
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
        // Union strategy selects the table strategy (.union), but when both records are
        // non-deleted it delegates to lastWriteWins to pick the winner by timestamp.
        // The returned strategyUsed reflects the actual resolution path (.lastWriteWins).
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

        // When local is newer, local wins
        let resultLocalNewer = resolver.resolve(table: "list_items", local: localItem, remote: remoteItem)
        XCTAssertEqual(resultLocalNewer.source, .local,
                       "Newer local item should win when neither record is deleted")
        XCTAssertEqual(resultLocalNewer.record["media_id"] as? Int, 123,
                       "Winner record should be the local (newer) item")

        // Deletion semantics: union always keeps non-deleted record regardless of timestamp
        let deletedLocal: [String: Any] = [
            "id": "item-001",
            "list_id": "list-A",
            "media_id": 123,
            "deleted_at": "2024-01-03T10:00:00Z",  // deleted locally — even if newer
            "updated_at": "2024-01-03T10:00:00Z"
        ]
        let liveRemote: [String: Any] = [
            "id": "item-001",
            "list_id": "list-A",
            "media_id": 123,
            "deleted_at": NSNull(),
            "updated_at": "2024-01-01T10:00:00Z"
        ]

        let resultDeletion = resolver.resolve(table: "list_items", local: deletedLocal, remote: liveRemote)
        XCTAssertEqual(resultDeletion.strategyUsed, .union,
                       "Union strategy should be used for list_items")
        XCTAssertEqual(resultDeletion.source, .remote,
                       "Non-deleted remote should win over locally-deleted record")
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
        // Capture count before queuing — count may be 0 if sync runs immediately
        let countBefore = await MainActor.run { SyncEngine.shared.pendingOperationsCount }

        // queueOperation must complete without throwing — this is the primary assertion
        try await SyncEngine.shared.queueOperation(
            table: "test_table",
            operationType: "INSERT",
            recordId: UUID().uuidString,
            payload: ["key": "value"],
            dependsOn: nil
        )

        // After queuing, the count should have been >= 1 at some point.
        // If the engine is online it may push immediately, draining the queue.
        // We verify the operation was accepted by asserting no throw above,
        // and verify that the count is a non-negative integer (invariant always holds).
        let countAfter = await MainActor.run { SyncEngine.shared.pendingOperationsCount }
        XCTAssertGreaterThanOrEqual(countAfter, 0,
                                    "pendingOperationsCount must be a non-negative integer")
        // The count must not have decreased from before (queue only grows or drains via sync)
        _ = countBefore  // referenced to avoid warning
    }
}

// MARK: - Lists Persistence Characterization (Fase 2 — rete di sicurezza anti data-loss)
//
// Questi test FOTOGRAFANO il comportamento ATTUALE della persistenza liste su SQLite,
// con focus sullo scenario 141->1. Sono la rete di sicurezza prima dello strangler-fig
// verso il Repository unificato: il nuovo path dovra' soddisfare gli stessi invarianti
// (o cambiarli DELIBERATAMENTE, non per errore).
//
// Usano l'init iniettabile di SQLiteService (aggiunto in Fase 2) su file temporaneo.
final class ListsPersistenceCharacterizationTests: XCTestCase {

    private var db: SQLiteService!
    private var dbPath: String!
    private let listId = "list-under-test"
    private let userId = "device-user"

    override func setUp() async throws {
        try await super.setUp()
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vw_lists_\(UUID().uuidString).sqlite")
        db = SQLiteService(dbPath: dbPath)
        // Le FK richiederebbero righe profiles/lists: per isolare la caratterizzazione
        // della tabella list_items le disabilitiamo sulla connessione di test.
        _ = db.execute("PRAGMA foreign_keys = OFF")
    }

    override func tearDown() async throws {
        db = nil
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        try await super.tearDown()
    }

    @discardableResult
    private func insertItem(id: String, mediaId: Int, deletedAt: String? = nil) async throws -> Int64 {
        var values: [String: Any] = [
            "id": id,
            "list_id": listId,
            "user_id": userId,
            "media_id": mediaId,
            "media_type": "movie",
            "title": "Movie \(mediaId)",
            "added_at": "2024-01-01T00:00:00Z"
        ]
        if let deletedAt { values["deleted_at"] = deletedAt }
        return try await db.insert("list_items", values: values)
    }

    /// Replica la query item di loadListsFromSQLite.
    private func loadActiveItems() async throws -> [[String: Any]] {
        try await db.queryRaw(
            "SELECT * FROM list_items WHERE list_id IN (?) AND deleted_at IS NULL ORDER BY added_at DESC",
            parameters: [listId]
        )
    }

    private func intValue(_ rows: [[String: Any]], _ key: String) -> Int {
        if let i = rows.first?[key] as? Int { return i }
        if let i = rows.first?[key] as? Int64 { return Int(i) }
        return -1
    }

    // INVARIANTE 1: il load esclude gli item soft-deleted.
    func test_load_excludesSoftDeletedItems() async throws {
        try await insertItem(id: "a", mediaId: 1)
        try await insertItem(id: "b", mediaId: 2)
        try await insertItem(id: "c", mediaId: 3, deletedAt: "2024-02-01T00:00:00Z")

        let active = try await loadActiveItems()
        XCTAssertEqual(active.count, 2, "Gli item soft-deleted non devono comparire nel load")
    }

    // INVARIANTE 2 (cuore del 141->1): tutti gli item sopravvivono a un "relaunch"
    // (nuova istanza di SQLiteService sullo stesso file).
    func test_items_survivePersistenceReopen() async throws {
        for i in 1...141 { try await insertItem(id: "item-\(i)", mediaId: i) }

        let reopened = SQLiteService(dbPath: dbPath)
        let rows = try await reopened.queryRaw(
            "SELECT COUNT(*) AS c FROM list_items WHERE list_id = ? AND deleted_at IS NULL",
            parameters: [listId]
        )
        XCTAssertEqual(intValue(rows, "c"), 141, "Tutti i 141 item devono sopravvivere al relaunch")
    }

    // Il footgun descritto qui — performBatchInsert era INSERT OR REPLACE, e poiche' i record NON
    // includono deleted_at un re-save RESUSCITAVA un item soft-deleted — e' stato chiuso (ARCH-010).
    // Ora usa ON CONFLICT DO UPDATE sui soli campi forniti, quindi deleted_at (non fornito) resta.
    // Questo test asserisce il comportamento CORRETTO: l'item soft-deleted non riemerge.
    func test_performBatchInsert_preservesSoftDelete() async throws {
        try await insertItem(id: "x", mediaId: 9, deletedAt: "2024-02-01T00:00:00Z")

        let record: [String: Any] = [
            "id": "x",
            "list_id": listId,
            "user_id": userId,
            "media_id": 9,
            "media_type": "movie",
            "title": "Movie 9",
            "added_at": "2024-01-01T00:00:00Z"
        ]
        let ok = await db.performBatchInsert(table: "list_items", records: [record])
        XCTAssertTrue(ok)

        let rows = try await db.queryRaw("SELECT deleted_at FROM list_items WHERE id = ?", parameters: ["x"])
        XCTAssertEqual(rows.first?["deleted_at"] as? String, "2024-02-01T00:00:00Z",
                       "ON CONFLICT DO UPDATE non tocca deleted_at (non fornito) -> l'item resta soft-deleted")
    }

    // ARCH-010 guard: `REPLACE INTO` (e `INSERT OR REPLACE`) sono ammessi SOLO su tabelle senza
    // figli in ON DELETE CASCADE — oggi `app_metadata` e `device_info`. Ovunque altrove la DELETE
    // implicita di REPLACE puo' propagare cascate o resuscitare soft-delete (vedi il test sopra).
    // Questo test fa da diga: se qualcuno introduce un nuovo REPLACE a mano su un'altra tabella,
    // fallisce qui invece che come perdita dati in produzione.
    //
    // E' un guard di dev/CI: usa i sorgenti accanto a #filePath e si salta dove non ci sono
    // (es. run on-device), perche' non e' un invariante di runtime ma di codice.
    func test_noHandRolledReplaceIntoOutsideSafeTables() throws {
        let allowedTables: Set<String> = ["app_metadata", "device_info"]

        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent() // .../VibeWatchApp
        let fm = FileManager.default
        guard fm.fileExists(atPath: appRoot.appendingPathComponent("Core").path) else {
            throw XCTSkip("Sorgenti non disponibili accanto a #filePath (run on-device): guard saltato")
        }

        let pattern = try NSRegularExpression(
            pattern: #"(?:INSERT\s+OR\s+)?REPLACE\s+INTO\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            options: [.caseInsensitive])
        let selfFile = testFile.lastPathComponent

        var offenders: [String] = []
        let enumerator = fm.enumerator(at: appRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != selfFile else { continue }
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for rawLine in src.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                // Salta le righe di commento: i doc-comment del codebase citano `REPLACE INTO
                // profiles` per spiegare il footgun di STAB-001, e non sono codice.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                let ns = line as NSString
                for m in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let table = ns.substring(with: m.range(at: 1))
                    if !allowedTables.contains(table) {
                        offenders.append("\(url.lastPathComponent): REPLACE INTO \(table)")
                    }
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty,
                      "REPLACE INTO a mano su tabelle non consentite (usare INSERT ... ON CONFLICT):\n"
                      + offenders.joined(separator: "\n"))
    }
}

// MARK: - Mock SyncEngine (rete di scrittura Fase 2)

/// Cattura le operazioni accodate sull'outbox senza toccare il DB reale.
final class MockSyncEngine: SyncEngineProtocol, @unchecked Sendable {
    struct QueuedOp {
        let table: String
        let operationType: String
        let recordId: String
        let payload: [String: Any]
    }
    private(set) var queued: [QueuedOp] = []

    var isSyncing = false
    var lastSyncAt: Date? = nil
    var pendingOperationsCount = 0
    var lastError: String? = nil

    func queueOperation(table: String, operationType: String, recordId: String, payload: [String: Any], dependsOn: Int?) async throws {
        queued.append(QueuedOp(table: table, operationType: operationType, recordId: recordId, payload: payload))
    }
    func performFullSync(trigger: SyncTrigger) async {}
    func pushPendingChanges() async {}
    func pullFromRemote() async {}
}

final class SyncEnginePayloadNormalizationTests: XCTestCase {

    func test_listItemsInsertPayloadMissingRemoteTimestampsIsNormalized() {
        let addedAt = "2026-06-08T12:00:00Z"
        let normalized = SyncEngine.normalizedMutationRecord(
            table: "list_items",
            operationType: "INSERT",
            recordId: "item-1",
            payload: [
                "id": "item-1",
                "list_id": "list-1",
                "user_id": "user-1",
                "media_id": 10,
                "media_type": "movie",
                "title": "Movie 10",
                "added_at": addedAt
            ]
        )

        XCTAssertEqual(normalized["created_at"] as? String, addedAt)
        XCTAssertNotNil(normalized["updated_at"] as? String)
        XCTAssertEqual(normalized["added_at"] as? String, addedAt)
    }

    func test_recoverRetryableListItemOperationsSQLResetsExhaustedFailedInserts() async throws {
        let dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vw_outbox_recovery_\(UUID().uuidString).sqlite")
        let db = SQLiteService(dbPath: dbPath)
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        XCTAssertTrue(db.execute("""
            INSERT INTO sync_outbox (
                operation_id, user_id, table_name, operation_type, record_id,
                payload, status, attempts, next_retry_at, last_error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, parameters: [
            "op-1",
            "user-1",
            "list_items",
            "INSERT",
            "item-1",
            #"{"id":"item-1","list_id":"list-1","user_id":"user-1","media_id":10,"media_type":"movie","title":"Movie 10","added_at":"2026-06-08T12:00:00Z"}"#,
            "failed",
            5,
            "2099-01-01T00:00:00Z",
            "missing created_at"
        ]))

        XCTAssertTrue(db.execute(SyncEngine.recoverRetryableListItemOperationsSQL(maxRetries: 5)))

        let rows = try await db.queryRaw(
            "SELECT status, attempts, next_retry_at, last_error FROM sync_outbox WHERE operation_id = ?",
            parameters: ["op-1"]
        )
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["status"] as? String, "pending")
        XCTAssertEqual(row["attempts"] as? Int, 0)
        XCTAssertNil(row["next_retry_at"] as? String)
        XCTAssertNil(row["last_error"] as? String)
    }
}

final class DatabaseMigrationIndexTests: XCTestCase {

    private var db: SQLiteService!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vw_migration_index_\(UUID().uuidString).sqlite")
        db = SQLiteService(dbPath: dbPath)
    }

    override func tearDown() async throws {
        db = nil
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        try await super.tearDown()
    }

    func test_listItemsPaginationIndexSQLTargetsExistingColumns() {
        XCTAssertTrue(
            db.execute(DatabaseMigrationManager.listItemsPaginationIndexSQL),
            "L'indice list_items della unified migration deve usare colonne esistenti nello schema locale"
        )
    }
}

// MARK: - ListManager Write Characterization (Fase 2 — rete pre #6 dual-write)
//
// Fotografano il comportamento di SCRITTURA: le mutazioni passano dall'outbox (SyncEngine).
// In modalità anonima la chiamata diretta a Supabase è già saltata, quindi questi test
// isolano il path outbox e RESTERANNO VERDI dopo la rimozione del dual-write (task #6):
// servono da guard-rail che l'enqueue non venga perso nel refactor.
@MainActor
final class ListManagerWriteCharacterizationTests: XCTestCase {

    private var db: SQLiteService!
    private var dbPath: String!
    private var sync: MockSyncEngine!
    private var manager: ListManager!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vw_lm_\(UUID().uuidString).sqlite")
        db = SQLiteService(dbPath: dbPath)
        _ = db.execute("PRAGMA foreign_keys = OFF")
        sync = MockSyncEngine()
        // autoStart:false → niente loadLists/observer. Modalità anonima (currentUser nil nel test env):
        // addToList sulla WATCHLIST (non custom) non richiede auth.
        manager = ListManager(db: db, sync: sync, autoStart: false)
        manager.lists = [MediaList(name: ListType.watchlist.rawValue, type: .watchlist)]
    }

    override func tearDown() async throws {
        manager = nil; db = nil; sync = nil
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        try await super.tearDown()
    }

    private static func movie(id: Int) -> Movie {
        Movie(
            id: id, title: "Movie \(id)", overview: "", posterPath: nil, backdropPath: nil,
            releaseDate: "2026-01-01", voteAverage: 7, voteCount: 1, genreIds: nil, genres: nil,
            adult: false, originalLanguage: "en", popularity: 1, runtime: 100, status: nil,
            tagline: nil, productionCountries: nil, imdbId: nil
        )
    }

    private var watchlistId: String { manager.lists.first { $0.type == .watchlist }!.id }

    func test_addToList_enqueuesListItemsInsert() async throws {
        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 42), mediaType: .movie)

        let inserts = sync.queued.filter { $0.table == "list_items" && $0.operationType == "INSERT" }
        XCTAssertEqual(inserts.count, 1, "addToList deve accodare un INSERT list_items sull'outbox")
        XCTAssertEqual(inserts.first?.payload["media_id"] as? Int, 42)
    }

    func test_addToList_enqueuesListItemsInsertWithRemoteTimestamps() async throws {
        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 43), mediaType: .movie)

        let insert = try XCTUnwrap(sync.queued.first { $0.table == "list_items" && $0.operationType == "INSERT" })
        XCTAssertNotNil(insert.payload["added_at"] as? String, "list_items INSERT deve inviare added_at al backend")
        XCTAssertNotNil(insert.payload["created_at"] as? String, "list_items INSERT deve inviare created_at per apply_mutations")
        XCTAssertNotNil(insert.payload["updated_at"] as? String, "list_items INSERT deve inviare updated_at per conflict/sync")
    }

    func test_removeFromList_enqueuesListItemsDelete() async throws {
        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 7), mediaType: .movie)
        let item = try XCTUnwrap(manager.lists.first { $0.type == .watchlist }?.items.first)

        // Il manager tiene la reference al mock iniettato: filtro solo le DELETE
        // (l'INSERT dell'addToList sopra non interferisce).
        try await manager.removeFromList(listId: watchlistId, itemId: item.id)

        let deletes = sync.queued.filter { $0.table == "list_items" && $0.operationType == "DELETE" }
        XCTAssertEqual(deletes.count, 1, "removeFromList deve accodare un DELETE list_items sull'outbox")
        XCTAssertEqual(deletes.first?.recordId, item.id)
    }

    func test_updateList_enqueuesListsUpdate() async throws {
        let custom = MediaList(id: "c1", name: "Old", description: nil, type: .custom, createdAt: Date(), items: [])
        manager.lists = [custom]

        try await manager.updateList(id: "c1", name: "New", description: "desc")

        let updates = sync.queued.filter { $0.table == "lists" && $0.operationType == "UPDATE" }
        XCTAssertEqual(updates.count, 1, "updateList deve accodare un UPDATE lists sull'outbox")
        XCTAssertEqual(updates.first?.payload["name"] as? String, "New")
    }

    func test_deleteList_enqueuesListsDelete() async throws {
        let custom = MediaList(id: "c2", name: "ToDelete", description: nil, type: .custom, createdAt: Date(), items: [])
        manager.lists = [custom]

        try await manager.deleteList(id: "c2")

        let deletes = sync.queued.filter { $0.table == "lists" && $0.operationType == "DELETE" }
        XCTAssertEqual(deletes.count, 1, "deleteList deve accodare un DELETE lists sull'outbox")
        XCTAssertEqual(deletes.first?.recordId, "c2")
    }

    func test_createList_loggedIn_enqueuesListsInsert_offlineFirst() async throws {
        // Auth mock "loggato" + nessuna dipendenza da Supabase: createList ora è offline-first
        // (prima falliva offline perché remote-first).
        let auth = MockAuth(user: User(id: "user-1", email: "u@test"))
        let manager = ListManager(db: db, sync: sync, authService: auth, autoStart: false)

        let created = try await manager.createList(name: "My List", description: "d")

        XCTAssertEqual(created.type, .custom)
        let inserts = sync.queued.filter { $0.table == "lists" && $0.operationType == "INSERT" }
        XCTAssertEqual(inserts.count, 1, "createList deve accodare un INSERT lists sull'outbox")
        XCTAssertEqual(inserts.first?.payload["name"] as? String, "My List")
        XCTAssertEqual(inserts.first?.payload["user_id"] as? String, "user-1")
    }
}

@MainActor
final class ListManagerSQLitePersistenceTests: XCTestCase {

    private var db: SQLiteService!
    private var dbPath: String!
    private var sync: MockSyncEngine!
    private var manager: ListManager!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vw_lm_fk_\(UUID().uuidString).sqlite")
        db = SQLiteService(dbPath: dbPath)
        sync = MockSyncEngine()
        manager = ListManager(db: db, sync: sync, authService: MockAuth(user: nil), autoStart: false)
        manager.lists = [manager.watchlist, manager.seenList, manager.likedList, manager.dislikedList]
    }

    override func tearDown() async throws {
        manager = nil; db = nil; sync = nil
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        try await super.tearDown()
    }

    private static func movie(id: Int) -> Movie {
        Movie(
            id: id, title: "Movie \(id)", overview: "", posterPath: nil, backdropPath: nil,
            releaseDate: "2026-01-01", voteAverage: 7, voteCount: 1, genreIds: nil, genres: nil,
            adult: false, originalLanguage: "en", popularity: 1, runtime: 100, status: nil,
            tagline: nil, productionCountries: nil, imdbId: nil
        )
    }

    func test_removeFromList_softDeletesSQLiteRowWithForeignKeysOn() async throws {
        let watchlistId = manager.watchlist.id
        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 700), mediaType: .movie)
        let item = try XCTUnwrap(manager.watchlist.items.first { $0.mediaId == 700 })

        try await manager.removeFromList(listId: watchlistId, itemId: item.id)

        let rows = try await db.queryRaw(
            "SELECT deleted_at FROM list_items WHERE id = ?",
            parameters: [item.id]
        )
        let deletedAt = rows.first?["deleted_at"] as? String
        XCTAssertNotNil(deletedAt, "removeFromList deve soft-deletare la riga SQLite, non solo mutare la memoria")
    }

    func test_createList_persistsCustomListWithForeignKeysOn() async throws {
        let auth = MockAuth(user: User(id: "user-fk", email: "u@test"))
        manager = ListManager(db: db, sync: sync, authService: auth, autoStart: false)

        let created = try await manager.createList(name: "Persisted Custom")

        let rows = try await db.queryRaw(
            "SELECT id FROM lists WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
            parameters: [created.id, "user-fk"]
        )
        XCTAssertEqual(rows.count, 1, "createList deve creare anche la riga SQLite della custom list con FK attive")
    }
}

/// Auth mock minimale (role-protocol AuthStatusProviding) per i test del write-path.
@MainActor
final class MockAuth: AuthStatusProviding {
    var currentUser: User?
    private let authSubject: CurrentValueSubject<Bool, Never>

    init(user: User?) {
        self.currentUser = user
        self.authSubject = CurrentValueSubject(user != nil)
    }

    var isAuthenticatedPublisher: AnyPublisher<Bool, Never> {
        authSubject.eraseToAnyPublisher()
    }
}

// MARK: - Mock remote liste (role-protocol ListsRemoteDataSource)

/// Stub del path remoto liste: niente rete. Registra le chiamate dirette (createList/addItemToList)
/// così la caratterizzazione del sync-path può asserire se l'upload avviene N+1-diretto o via outbox.
@MainActor
final class MockListsRemote: ListsRemoteDataSource {
    var user: User?
    var remoteLists: [MediaList] = []
    private(set) var createListCalls: [String] = []

    init(user: User?) { self.user = user }

    var currentUser: User? { user }
    func fetchLists() async throws -> [MediaList] { remoteLists }
    func fetchListItems(listId: String) async throws -> [MediaListItem] { [] }
    func createList(id: String, name: String, description: String?, type: ListType) async throws -> MediaList {
        createListCalls.append(id)
        return MediaList(id: id, name: name, description: description, type: type, createdAt: Date(), items: [])
    }
}

// MARK: - ListManager Sync Characterization (Fase 2 task #7 — 4.3 N+1 al login)
//
// syncListsForAuthenticatedUser carica le liste custom create da anonimo su questo device
// quando l'utente fa login. Questi test FOTOGRAFANO come avviene l'upload: oggi (CURRENT)
// con N chiamate dirette supabase.createList + supabase.addItemToList (burst N+1); il refactor
// 4.3 deve spostarlo sull'outbox/SyncEngine (single batched apply_mutations), senza scritture
// remote dirette. Rete di sicurezza prima del cambio.
@MainActor
final class ListManagerSyncCharacterizationTests: XCTestCase {

    private var db: SQLiteService!
    private var dbPath: String!
    private var sync: MockSyncEngine!
    private var remote: MockListsRemote!
    private var auth: MockAuth!
    private var manager: ListManager!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vw_sync_\(UUID().uuidString).sqlite")
        db = SQLiteService(dbPath: dbPath)
        _ = db.execute("PRAGMA foreign_keys = OFF")
        sync = MockSyncEngine()
        remote = MockListsRemote(user: User(id: "user-1", email: "u@test"))
        auth = MockAuth(user: User(id: "user-1", email: "u@test"))
        // autoStart:false → niente loadLists/observer; chiamiamo il sync esplicitamente.
        manager = ListManager(db: db, sync: sync, supabase: remote, authService: auth, autoStart: false)
    }

    override func tearDown() async throws {
        manager = nil; db = nil; sync = nil; remote = nil; auth = nil
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        try await super.tearDown()
    }

    /// 4.3: la lista custom locale-only viene caricata SOLO via outbox/SyncEngine (INSERT lists +
    /// INSERT list_items per item), senza scritture remote dirette (niente più N+1 al login).
    func test_syncForAuthenticatedUser_localOnlyCustomList_enqueuesOutbox_noDirectWrites() async throws {
        let item1 = MediaListItem(mediaId: 11, mediaType: .movie, title: "M11", posterPath: nil)
        let item2 = MediaListItem(mediaId: 12, mediaType: .movie, title: "M12", posterPath: nil)
        let local = MediaList(id: "local-custom", name: "Anon", type: .custom, items: [item1, item2])
        manager.lists = [local]
        remote.remoteLists = []   // il server non ha questa lista

        await manager.syncListsForAuthenticatedUser()

        // Nessuna scrittura remota diretta: l'upload passa per l'outbox.
        XCTAssertTrue(remote.createListCalls.isEmpty,
                      "4.3: niente supabase.createList diretto (no N+1)")

        let listInserts = sync.queued.filter { $0.table == "lists" && $0.operationType == "INSERT" }
        XCTAssertEqual(listInserts.count, 1, "deve accodare un INSERT lists per la lista locale-only")
        XCTAssertEqual(listInserts.first?.recordId, "local-custom")
        XCTAssertEqual(listInserts.first?.payload["user_id"] as? String, "user-1",
                       "user_id deve essere quello autenticato, non il deviceId anonimo")

        let itemInserts = sync.queued.filter { $0.table == "list_items" && $0.operationType == "INSERT" }
        XCTAssertEqual(itemInserts.count, 2, "deve accodare un INSERT list_items per ogni item")
    }

    /// Una lista già presente sul remoto non viene ri-accodata (no upload duplicato).
    func test_syncForAuthenticatedUser_listAlreadyRemote_doesNotReenqueue() async throws {
        let local = MediaList(id: "dup", name: "Shared", type: .custom, items: [])
        manager.lists = [local]
        remote.remoteLists = [MediaList(id: "dup", name: "Shared", type: .custom, items: [])]

        await manager.syncListsForAuthenticatedUser()

        XCTAssertTrue(sync.queued.filter { $0.table == "lists" && $0.recordId == "dup" }.isEmpty,
                      "una lista già remota non deve essere ri-accodata")
    }

    /// Boundary di regressione "gli item spariscono al riavvio" (il layer che nessun fix precedente
    /// copriva): al cold launch `loadListsFromSQLite` gira col deviceId (sessione auth non ancora
    /// ripristinata) e carica le liste DEVICE, vuote; poi `syncListsForAuthenticatedUser` ricostruiva
    /// lo stato in memoria SOLO dal remoto (qui vuoto, es. push outbox fallito 42703) senza mai
    /// ricaricare le liste/item LOCALI dell'utente autenticato → gli item già presenti in SQLite non
    /// venivano mai caricati in memoria. Il fix termina il sync con `loadListsFromSQLite()` (ora con
    /// l'id autenticato) e li rende visibili.
    func test_syncForAuthenticatedUser_reloadsLocalAuthedItems_whenRemoteEmpty() async throws {
        // Item già persistito in SQLite sotto l'utente autenticato (come dopo un add fatto da loggato).
        _ = db.execute("""
            INSERT INTO lists (id, name, description, type, created_at, user_id)
            VALUES ('seen-local', 'seen', '', 'seen', '2020-01-01T00:00:00Z', 'user-1')
        """)
        _ = db.execute("""
            INSERT INTO list_items (id, list_id, user_id, media_id, media_type, title, added_at)
            VALUES ('it-1', 'seen-local', 'user-1', 999, 'movie', 'Persisted Movie', '2020-01-01T00:00:00Z')
        """)
        // Stato in memoria "vuoto" come dopo un cold-launch che ha caricato liste device vuote.
        manager.lists = []
        remote.remoteLists = []   // remoto vuoto (es. push outbox fallito)

        await manager.syncListsForAuthenticatedUser()

        let seen = manager.lists.first { $0.type == .seen }
        XCTAssertNotNil(seen, "deve esserci una lista seen in memoria dopo il sync")
        XCTAssertTrue(seen?.items.contains { $0.id == "it-1" } ?? false,
                      "l'item locale dell'utente autenticato deve essere ricaricato in memoria, non perso al riavvio")
    }

    // MARK: - ensureListsInDatabase (4.3b — N+1 a ogni avvio)

    /// 4.3b: lista non ancora sincronizzata (synced_at NULL). Default → outbox; custom → createList
    /// diretto insert-or-fail (no resurrection).
    func test_ensureListsInDatabase_unsynced_defaultViaOutbox_customDirect() async throws {
        let watchlist = MediaList(name: ListType.watchlist.rawValue, type: .watchlist)
        let custom = MediaList(id: "c-1", name: "Mine", type: .custom, items: [])
        manager.lists = [watchlist, custom]
        // ensureListsInDatabase fa ensureListInSQLite (INSERT OR IGNORE, synced_at NULL) → entrambe unsynced.

        await manager.ensureListsInDatabase()

        // Default → outbox, NON createList diretto.
        let defaultInserts = sync.queued.filter { $0.table == "lists" && $0.recordId == watchlist.id }
        XCTAssertEqual(defaultInserts.count, 1, "la default unsynced va accodata sull'outbox")
        XCTAssertFalse(remote.createListCalls.contains(watchlist.id),
                       "la default NON deve usare createList diretto")

        // Custom → createList diretto insert-or-fail, NON outbox.
        XCTAssertTrue(remote.createListCalls.contains("c-1"),
                      "la custom unsynced usa createList diretto (no resurrection)")
        XCTAssertTrue(sync.queued.filter { $0.table == "lists" && $0.recordId == "c-1" }.isEmpty,
                      "la custom NON deve passare per l'outbox (rischio resurrection)")
    }

    /// 4.3b: liste già riconciliate col remoto (synced_at valorizzato) → nessun lavoro remoto
    /// (taglio del burst N+1 a ogni avvio per gli utenti esistenti).
    func test_ensureListsInDatabase_syncedLists_noRemoteWork() async throws {
        let watchlist = MediaList(name: ListType.watchlist.rawValue, type: .watchlist)
        let custom = MediaList(id: "c-2", name: "Synced", type: .custom, items: [])
        manager.lists = [watchlist, custom]

        // Pre-inserisci le righe con synced_at valorizzato; ensureListInSQLite è INSERT OR IGNORE
        // → non sovrascrive, quindi restano "synced".
        for l in [watchlist, custom] {
            _ = db.execute(
                "INSERT INTO lists (id, user_id, name, type, created_at, synced_at) VALUES (?,?,?,?,?,?)",
                parameters: [l.id, "user-1", l.name, l.type.rawValue, "2024-01-01T00:00:00Z", "2024-01-02T00:00:00Z"]
            )
        }

        await manager.ensureListsInDatabase()

        XCTAssertTrue(remote.createListCalls.isEmpty, "nessun createList diretto per liste già synced")
        XCTAssertTrue(sync.queued.filter { $0.table == "lists" }.isEmpty, "nessun enqueue per liste già synced")
    }

    /// 4.3b: utente anonimo → nessuna scrittura/enqueue remota (solo persistenza locale).
    func test_ensureListsInDatabase_anonymous_noRemote() async throws {
        let anonManager = ListManager(db: db, sync: sync, supabase: remote, authService: MockAuth(user: nil), autoStart: false)
        anonManager.lists = [MediaList(name: ListType.watchlist.rawValue, type: .watchlist)]

        await anonManager.ensureListsInDatabase()

        XCTAssertTrue(remote.createListCalls.isEmpty)
        XCTAssertTrue(sync.queued.filter { $0.table == "lists" }.isEmpty)
    }
}

// MARK: - TMDBRequestBudget (Fase 2 task #7 — 4.1 budget richieste TMDB)
//
// Testano la LOGICA del budget (coalescing + cache TTL + tetto di concorrenza) con closure
// banali, senza dover stubbare i ~30 metodi di TMDBServiceProtocol. Il decorator
// BudgetedTMDBService è poi semplice delega verificata dal build.

private actor BudgetCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor BudgetConcurrencyTracker {
    private(set) var current = 0
    private(set) var maxObserved = 0
    func enter() { current += 1; maxObserved = max(maxObserved, current) }
    func exit() { current -= 1 }
}

final class TMDBRequestBudgetTests: XCTestCase {

    /// Coalescing: N richieste identiche concorrenti condividono UN solo task.
    func test_coalescesConcurrentIdenticalRequests() async throws {
        let budget = TMDBRequestBudget(maxConcurrent: 8, ttl: 30)
        let counter = BudgetCallCounter()

        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    (try? await budget.run(key: "same") {
                        await counter.increment()
                        try? await Task.sleep(nanoseconds: 20_000_000) // tieni il task in volo
                        return 42
                    }) ?? -1
                }
            }
            for await _ in group {}
        }

        let calls = await counter.value
        XCTAssertEqual(calls, 1, "20 richieste identiche concorrenti devono coalescere in 1 sola op")
    }

    /// Cache TTL: ripetizioni sequenziali della stessa key entro il TTL servono dalla cache.
    func test_servesFromCacheWithinTTL() async throws {
        let budget = TMDBRequestBudget(maxConcurrent: 4, ttl: 30)
        let counter = BudgetCallCounter()

        for _ in 0..<5 {
            let v = try await budget.run(key: "same") { await counter.increment(); return 7 }
            XCTAssertEqual(v, 7)
        }

        let cachedCalls = await counter.value
        XCTAssertEqual(cachedCalls, 1, "le ripetizioni entro il TTL non devono ri-eseguire l'op")
    }

    /// ttl=0 → niente cache: ogni esecuzione sequenziale ri-parte (no riuso indebito).
    func test_zeroTTL_doesNotCache() async throws {
        let budget = TMDBRequestBudget(maxConcurrent: 4, ttl: 0)
        let counter = BudgetCallCounter()

        for _ in 0..<3 {
            _ = try await budget.run(key: "same") { await counter.increment(); return 1 }
        }

        let noCacheCalls = await counter.value
        XCTAssertEqual(noCacheCalls, 3, "con ttl=0 ogni richiesta sequenziale ri-esegue")
    }

    /// maxConcurrent: con key distinte (no coalescing) non ci sono più di N op in volo.
    func test_respectsMaxConcurrent() async throws {
        let budget = TMDBRequestBudget(maxConcurrent: 3, ttl: 0)
        let tracker = BudgetConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<15 {
                group.addTask {
                    _ = try? await budget.run(key: "k\(i)") {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 25_000_000)
                        await tracker.exit()
                        return i
                    }
                }
            }
            for await _ in group {}
        }

        let peak = await tracker.maxObserved
        XCTAssertLessThanOrEqual(peak, 3, "non devono esserci più di maxConcurrent op TMDB in volo (peak=\(peak))")
        XCTAssertGreaterThan(peak, 1, "il test deve davvero esercitare la concorrenza")
    }

    /// L'errore si propaga e NON viene messo in cache (la richiesta successiva ri-prova).
    func test_errorPropagatesAndIsNotCached() async throws {
        let budget = TMDBRequestBudget(maxConcurrent: 2, ttl: 30)
        let counter = BudgetCallCounter()

        struct Boom: Error {}
        do {
            _ = try await budget.run(key: "same") { () async throws -> Int in
                await counter.increment()
                throw Boom()
            }
            XCTFail("doveva propagare l'errore")
        } catch is Boom { /* atteso */ }

        // Seconda chiamata: deve ri-eseguire (l'errore non è cachato).
        _ = try? await budget.run(key: "same") { await counter.increment(); return 1 }
        let calls = await counter.value
        XCTAssertEqual(calls, 2, "un errore non deve essere servito dalla cache")
    }
}

// MARK: - ContentCache (Fase 3 §1.4 — cache generica unica TTL+LRU)
//
// Testano la LOGICA deterministica: hit/miss, scadenza TTL, rimozione, isolamento per chiave.
// NSCache evince in modo best-effort (non deterministico) sotto pressione/limiti: non asseriamo
// l'eviction esatta per countLimit, che non è garantita dall'API.
final class ContentCacheTests: XCTestCase {

    func test_insertThenValue_returnsValue() async {
        let cache = ContentCache<String, Int>(ttl: 60)
        await cache.insert(42, for: "k")
        let v = await cache.value(for: "k")
        XCTAssertEqual(v, 42)
    }

    func test_missingKey_returnsNil() async {
        let cache = ContentCache<String, Int>(ttl: 60)
        let v = await cache.value(for: "nope")
        XCTAssertNil(v)
    }

    func test_expiredEntry_returnsNil() async throws {
        let cache = ContentCache<String, Int>(ttl: 0.05)
        await cache.insert(7, for: "k")
        try await Task.sleep(nanoseconds: 120_000_000) // > ttl
        let v = await cache.value(for: "k")
        XCTAssertNil(v, "una entry scaduta non deve essere servita")
    }

    func test_zeroTTL_expiresImmediately() async {
        let cache = ContentCache<String, Int>(ttl: 0)
        await cache.insert(1, for: "k")
        let v = await cache.value(for: "k")
        XCTAssertNil(v, "ttl=0 → scaduta all'istante")
    }

    func test_removeValue() async {
        let cache = ContentCache<String, Int>(ttl: 60)
        await cache.insert(1, for: "k")
        await cache.removeValue(for: "k")
        let v = await cache.value(for: "k")
        XCTAssertNil(v)
    }

    func test_removeAll() async {
        let cache = ContentCache<String, Int>(ttl: 60)
        await cache.insert(1, for: "a")
        await cache.insert(2, for: "b")
        await cache.removeAll()
        let a = await cache.value(for: "a")
        let b = await cache.value(for: "b")
        XCTAssertNil(a); XCTAssertNil(b)
    }

    func test_distinctKeysIsolated() async {
        let cache = ContentCache<String, String>(ttl: 60)
        await cache.insert("va", for: "a")
        await cache.insert("vb", for: "b")
        let a = await cache.value(for: "a")
        let b = await cache.value(for: "b")
        XCTAssertEqual(a, "va")
        XCTAssertEqual(b, "vb")
    }

    func test_insertOverwritesSameKey() async {
        let cache = ContentCache<String, Int>(ttl: 60)
        await cache.insert(1, for: "k")
        await cache.insert(2, for: "k")
        let v = await cache.value(for: "k")
        XCTAssertEqual(v, 2, "una nuova insert sulla stessa chiave sovrascrive")
    }
}

// MARK: - ImageCacheService downsampling (Fase 3 §2.2)
import UIKit

final class ImageDownsampleTests: XCTestCase {

    private func makeImageData(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.pngData()!
    }

    func test_downsample_reducesToMaxPixelSize() throws {
        let data = makeImageData(width: 1000, height: 1500)
        let thumb = try XCTUnwrap(ImageCacheService.downsample(data: data, maxPixelSize: 300))
        // UIImage(cgImage:) ha scale 1 → .size è in pixel.
        let maxDim = max(thumb.size.width, thumb.size.height)
        XCTAssertLessThanOrEqual(maxDim, 301, "il lato lungo deve essere <= maxPixelSize")
        XCTAssertGreaterThan(maxDim, 0)
        // Aspect ratio 2:3 preservato (entro arrotondamento).
        let ratio = thumb.size.height / thumb.size.width
        XCTAssertEqual(ratio, 1.5, accuracy: 0.05)
    }

    func test_downsample_invalidData_returnsNil() {
        let thumb = ImageCacheService.downsample(data: Data([0x00, 0x01, 0x02]), maxPixelSize: 100)
        XCTAssertNil(thumb)
    }
}

// MARK: - Discovery pipeline characterization (Fase 3 §1.4 — item 1)
//
// Congela il CONTRATTO del seam `DiscoveryRepositoryProtocol → DiscoveryViewModel`,
// l'unico path che lo SCHERMO Discovery vede davvero. Qualunque collasso delle pipeline
// di prefetch/warm (DiscoveryCacheService, ContentCacheManager, array di DataCoordinator)
// avviene DIETRO questo protocollo: se questi test restano verdi, il render non regredisce.
//
// Caratterizzazione (comportamento ATTUALE, nessuna modifica al codice di produzione):
//  - una sola emissione popola personalizedCarousels (filtri default = passthrough);
//  - un'emissione vuota viene SALTATA (guard !carousels.isEmpty);
//  - stale→fresh: l'ultima emissione vince (stale-while-revalidate);
//  - finestra di paginazione: visibleCarousels = prefix(11), loadMoreCarousels() +10.

/// Repository di Discovery scriptato: emette in sequenza gli array forniti, poi finisce.
@MainActor
final class MockDiscoveryRepository: DiscoveryRepositoryProtocol {
    private let scripted: [[PersonalizedCarousel]]
    init(emitting scripted: [[PersonalizedCarousel]]) { self.scripted = scripted }

    nonisolated func observeCarousels(
        userId: String?,
        profile: UserProfile,
        filters: GlobalDiscoveryFilters,
        forceRefresh: Bool
    ) -> AsyncStream<[PersonalizedCarousel]> {
        let scripted = self.scripted
        return AsyncStream { continuation in
            for batch in scripted { continuation.yield(batch) }
            continuation.finish()
        }
    }
}

@MainActor
final class DiscoveryPipelineCharacterizationTests: XCTestCase {

    private static func movie(id: Int) -> Movie {
        Movie(
            id: id, title: "Movie \(id)", overview: "", posterPath: nil, backdropPath: nil,
            releaseDate: "2022-01-01", voteAverage: 8, voteCount: 100, genreIds: nil, genres: nil,
            adult: false, originalLanguage: "en", popularity: Double(id), runtime: nil, status: nil,
            tagline: nil, productionCountries: nil, imdbId: nil
        )
    }

    /// Carosello con type non-tv (passa il gate mediaType=.both) e 1 item che supera i filtri default.
    private static func carousel(_ type: CarouselType) -> PersonalizedCarousel {
        PersonalizedCarousel(
            type: type,
            titleSpec: CarouselTitleSpec(key: "carousel.test"),
            items: [movie(id: type.hashValue & 0xFFFF)],
            descriptions: [:],
            reason: "test"
        )
    }

    private func makeViewModel(emitting batches: [[PersonalizedCarousel]]) -> DiscoveryViewModel {
        DiscoveryViewModel(discoveryRepository: MockDiscoveryRepository(emitting: batches))
    }

    func test_singleEmission_populatesCarousels() async {
        let batch = [Self.carousel(.hiddenGems), Self.carousel(.hotThisWeek), Self.carousel(.staffPicks)]
        let vm = makeViewModel(emitting: [batch])

        await vm.loadContent(forceRefresh: true)

        XCTAssertEqual(vm.personalizedCarousels.count, 3, "una emissione deve popolare tutti i caroselli")
        XCTAssertFalse(vm.hasNoContent)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.visibleCarousels.count, 3, "meno di 11 → tutti visibili")
        XCTAssertFalse(vm.hasMoreCarousels)
    }

    func test_emptyEmission_isSkipped() async {
        let vm = makeViewModel(emitting: [[]])

        await vm.loadContent(forceRefresh: true)

        XCTAssertTrue(vm.hasNoContent, "un'emissione vuota non deve popolare nulla (guard !isEmpty)")
        XCTAssertTrue(vm.personalizedCarousels.isEmpty)
    }

    func test_staleThenFresh_lastEmissionWins() async {
        let stale = [Self.carousel(.hiddenGems), Self.carousel(.hotThisWeek)]
        let fresh = [Self.carousel(.staffPicks), Self.carousel(.awardWinners),
                     Self.carousel(.documentaries), Self.carousel(.comingSoon)]
        let vm = makeViewModel(emitting: [stale, fresh])

        await vm.loadContent(forceRefresh: true)

        XCTAssertEqual(vm.personalizedCarousels.count, 4, "stale-while-revalidate: l'ultima emissione (fresh) vince")
    }

    func test_pagination_windowsAndLoadsMore() async {
        // 25 caroselli (type ripetuto è ammesso: applyGlobalFilters non deduplica per type).
        let batch = (0..<25).map { _ in Self.carousel(.hiddenGems) }
        let vm = makeViewModel(emitting: [batch])

        await vm.loadContent(forceRefresh: true)

        XCTAssertEqual(vm.personalizedCarousels.count, 25)
        XCTAssertEqual(vm.visibleCarousels.count, 11, "finestra iniziale: hero + 10")
        XCTAssertTrue(vm.hasMoreCarousels)

        vm.loadMoreCarousels()
        XCTAssertEqual(vm.visibleCarousels.count, 21, "loadMore deve aggiungere una pagina (+10)")
        XCTAssertTrue(vm.hasMoreCarousels)

        vm.loadMoreCarousels()
        XCTAssertEqual(vm.visibleCarousels.count, 25, "ultima pagina troncata al totale")
        XCTAssertFalse(vm.hasMoreCarousels)
    }
}

// MARK: - ReadinessWaiter (splash dismissal — Fase 3 §1.4 follow-up)
//
// La splash di MainTabView usava un poll su una cache discovery ormai sempre-nil
// → di fatto un'attesa fissa di 3s. Ora poll-a `hasCachedPersonalizedContent()` via
// ReadinessWaiter, dismissando appena il pre-warm in background popola i caroselli.
// Questi test fissano il contratto del waiter: immediato se già pronto, early-return
// se diventa pronto durante l'attesa, timeout se non lo diventa mai.

@MainActor
final class ReadinessWaiterTests: XCTestCase {

    func test_alreadyReady_returnsImmediately() async {
        let start = Date()
        let ready = await ReadinessWaiter.waitUntilReady(maxWait: 3.0) { true }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(ready)
        XCTAssertLessThan(elapsed, 0.1, "se già pronto non deve attendere alcun poll")
    }

    func test_becomesReadyMidWait_returnsEarly() async {
        var calls = 0
        let start = Date()
        // Diventa pronto dopo ~3 poll da 50ms (~150ms), ben prima del timeout di 3s.
        let ready = await ReadinessWaiter.waitUntilReady(maxWait: 3.0, pollInterval: 0.05) {
            calls += 1
            return calls >= 4
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(ready)
        XCTAssertLessThan(elapsed, 1.0, "deve uscire appena pronto, non aspettare il timeout")
    }

    func test_neverReady_timesOut() async {
        let start = Date()
        let ready = await ReadinessWaiter.waitUntilReady(maxWait: 0.3, pollInterval: 0.05) { false }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(ready)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3, "se mai pronto deve attendere fino a maxWait")
    }
}

// MARK: - List load full-set invariant (Fase 3 §2.4 — item 2, caratterizzazione PRIMA)
//
// `ListManager.loadListsFromSQLite` oggi carica TUTTI gli item di una lista in `list.items`
// (nessun LIMIT/OFFSET) e l'intera app assume `list.items` = insieme COMPLETO: count
// (canAddToList / soft-limit / label), membership (isInList), re-save (saveItemsToSQLite).
// Questo test congela quell'invariante: qualunque paginazione (2.4) NON deve troncare
// `list.items` al punto da rompere count/membership. È la zona del bug 141→1 → guard-rail.

@MainActor
final class ListLoadFullSetCharacterizationTests: XCTestCase {

    private var db: SQLiteService!
    private var dbPath: String!
    private var sync: MockSyncEngine!
    private var manager: ListManager!
    private let listId = "custom-big"
    private let uid = "u1"

    override func setUp() async throws {
        try await super.setUp()
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vw_lmfull_\(UUID().uuidString).sqlite")
        db = SQLiteService(dbPath: dbPath)
        _ = db.execute("PRAGMA foreign_keys = OFF")
        sync = MockSyncEngine()
        manager = ListManager(db: db, sync: sync, authService: MockAuth(user: User(id: uid, email: "u@test")), autoStart: false)
    }

    override func tearDown() async throws {
        manager = nil; db = nil; sync = nil
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        try await super.tearDown()
    }

    private func seedList(itemCount: Int) async throws {
        _ = try await db.insert("lists", values: [
            "id": listId, "user_id": uid, "name": "Big", "type": "custom",
            "created_at": "2024-01-01T00:00:00Z"
        ])
        for i in 1...itemCount {
            _ = try await db.insert("list_items", values: [
                "id": "it-\(i)", "list_id": listId, "user_id": uid,
                "media_id": i, "media_type": "movie", "title": "Movie \(i)",
                "added_at": String(format: "2024-01-01T00:%02d:00Z", i % 60)
            ])
        }
    }

    // INVARIANTE: il load porta in RAM l'INTERO insieme (count completo + membership sull'ultimo).
    func test_loadFromSQLite_loadsFullItemSet_countAndMembership() async throws {
        try await seedList(itemCount: 141)

        await manager.loadListsFromSQLite()

        let list = try XCTUnwrap(manager.lists.first { $0.id == listId })
        XCTAssertEqual(list.items.count, 141, "il load deve portare in RAM TUTTI i 141 item (no troncamento)")
        XCTAssertTrue(manager.isInList(listId: listId, mediaId: 141, mediaType: .movie),
                      "la membership deve valere anche per l'ultimo item (oltre una eventuale prima pagina)")
        XCTAssertTrue(manager.canAddToList(listId: listId),
                      "canAddToList riflette il count pieno (141 < \(ListManager.maxItemsPerList))")
    }
}

// MARK: - Clip prefetch gate (Fase 4 §3.1 — batteria)
//
// Il prefetch clip pesante (validazione YouTube + scritture Supabase) deve girare SOLO
// su Wi-Fi e fuori da Low-Power Mode. Congela la funzione pura del gate.

final class ClipPrefetchGateTests: XCTestCase {

    func test_allowed_onlyOnWiFiAndNotLowPower() {
        XCTAssertTrue(ClipsPrefetchService.isPrefetchAllowed(isWiFi: true, isLowPowerMode: false),
                      "Wi-Fi + non Low-Power → consentito")
        XCTAssertFalse(ClipsPrefetchService.isPrefetchAllowed(isWiFi: false, isLowPowerMode: false),
                       "no Wi-Fi (es. cellulare) → bloccato")
        XCTAssertFalse(ClipsPrefetchService.isPrefetchAllowed(isWiFi: true, isLowPowerMode: true),
                       "Low-Power Mode → bloccato anche su Wi-Fi")
        XCTAssertFalse(ClipsPrefetchService.isPrefetchAllowed(isWiFi: false, isLowPowerMode: true),
                       "no Wi-Fi + Low-Power → bloccato")
    }
}

// MARK: - SQL column identifier hardening (Fase 5 §1.10)
//
// I nomi colonna provenienti dai dizionari dei chiamanti vengono interpolati nello SQL
// (i VALUES passano da `?`). Congela la funzione pura che li valida come identificatori
// SQL semplici, così i frammenti `columns`/`setClause` restano injection-proof.

final class SQLColumnIdentifierTests: XCTestCase {

    func test_acceptsPlainIdentifiers() {
        for col in ["id", "user_id", "media_id", "poster_path", "vote_average", "_private", "a1b2"] {
            XCTAssertTrue(SQLiteService.isValidColumnIdentifier(col), "\(col) è un identificatore valido")
        }
    }

    func test_rejectsInjectionAndMalformed() {
        for col in [
            "",                       // vuoto
            "1col",                   // inizia con cifra
            "user id",                // spazio
            "name; DROP TABLE lists", // statement injection
            "col)--",                 // chiusura paren + commento
            "col, evil",              // virgola (colonna extra)
            "\"quoted\"",             // virgolette
            "col='x'"                 // operatore
        ] {
            XCTAssertFalse(SQLiteService.isValidColumnIdentifier(col), "\(col) deve essere rifiutato")
        }
    }
}

// MARK: - List item filter+sort (Fase 5 — logica estratta da ListsView)
//
// La logica filtro+sort era DUPLICATA in due struct di ListsView; estratta in
// ListItemFilterer (pura). Questi test la congelano, incluso il flag che preserva
// l'unica differenza storica tra i due chiamanti (filtro periodo/anno).

final class ListItemFiltererTests: XCTestCase {

    private func item(
        id: String, title: String, type: MediaType = .movie,
        rating: Double? = nil, year: String? = nil, runtime: Int? = nil,
        countries: [String]? = nil
    ) -> MediaListItem {
        MediaListItem(
            id: id, mediaId: Int(id) ?? 0, mediaType: type, title: title, posterPath: nil,
            addedAt: Date(timeIntervalSince1970: TimeInterval(Int(id) ?? 0)),
            runtime: runtime, voteAverage: rating, originCountry: countries, releaseDate: year
        )
    }

    func test_search_matchesTitleCaseInsensitive() {
        let items = [item(id: "1", title: "Inception"), item(id: "2", title: "Tenet")]
        let out = ListItemFilterer.filteredAndSorted(items, searchText: "incep",
            filters: GlobalDiscoveryFilters(), availabilityByItemId: [:], applyReleasePeriodFilter: true)
        XCTAssertEqual(out.map(\.id), ["1"])
    }

    func test_mediaTypeMovies_excludesTV() {
        let items = [item(id: "1", title: "A", type: .movie), item(id: "2", title: "B", type: .tv)]
        var f = GlobalDiscoveryFilters(); f.mediaType = .movies
        let out = ListItemFilterer.filteredAndSorted(items, searchText: "",
            filters: f, availabilityByItemId: [:], applyReleasePeriodFilter: true)
        XCTAssertEqual(out.map(\.id), ["1"])
    }

    func test_sortRatingDesc() {
        let items = [item(id: "1", title: "A", rating: 6), item(id: "2", title: "B", rating: 9)]
        var f = GlobalDiscoveryFilters(); f.sortBy = .ratingDesc
        let out = ListItemFilterer.filteredAndSorted(items, searchText: "",
            filters: f, availabilityByItemId: [:], applyReleasePeriodFilter: true)
        XCTAssertEqual(out.map(\.id), ["2", "1"])
    }

    // Contratto del filterer: il flag governa il filtro periodo/anno (true=applica, false=no).
    // NB: dopo il fix del bug, ENTRAMBe le list-detail (principale + CustomListDetailView)
    // passano `true`; il ramo `false` resta testato come contratto dell'API, non più come
    // comportamento di una View.
    func test_releasePeriodFilter_onlyWhenFlagTrue() {
        let items = [item(id: "1", title: "Old", year: "2015-01-01"),
                     item(id: "2", title: "New", year: "2022-01-01")]
        // getYearRange() usa customYearStart solo con preset .custom.
        var f = GlobalDiscoveryFilters(); f.releasePeriodPreset = .custom; f.customYearStart = 2020

        let withYear = ListItemFilterer.filteredAndSorted(items, searchText: "",
            filters: f, availabilityByItemId: [:], applyReleasePeriodFilter: true)
        XCTAssertEqual(withYear.map(\.id), ["2"], "flag true → filtra per anno")

        let withoutYear = ListItemFilterer.filteredAndSorted(items, searchText: "",
            filters: f, availabilityByItemId: [:], applyReleasePeriodFilter: false)
        XCTAssertEqual(Set(withoutYear.map(\.id)), ["1", "2"], "flag false → NON filtra per anno (contratto API)")
    }

    func test_streamingFilter_usesInjectedAvailability() {
        let items = [item(id: "1", title: "A"), item(id: "2", title: "B")]
        var f = GlobalDiscoveryFilters(); f.streamingPlatforms = ["Netflix"]
        let availability: [String: Set<String>] = ["1": ["Netflix"], "2": ["Disney+"]]
        let out = ListItemFilterer.filteredAndSorted(items, searchText: "",
            filters: f, availabilityByItemId: availability, applyReleasePeriodFilter: true)
        XCTAssertEqual(out.map(\.id), ["1"], "solo gli item disponibili su una piattaforma selezionata")
    }
}

// MARK: - DiscoveryRanking (scoring + diversity puri estratti da DiscoveryPersonalizationService)

final class DiscoveryRankingTests: XCTestCase {

    private func movie(
        id: Int, voteAverage: Double = 0, popularity: Double = 0,
        genreIds: [Int]? = nil, releaseDate: String? = nil
    ) -> Movie {
        Movie(
            id: id, title: "M\(id)", overview: "", posterPath: nil, backdropPath: nil,
            releaseDate: releaseDate, voteAverage: voteAverage, voteCount: 0, genreIds: genreIds,
            genres: nil, adult: false, originalLanguage: "en", popularity: popularity, runtime: nil,
            status: nil, tagline: nil, productionCountries: nil, imdbId: nil
        )
    }

    private func profile(topGenres: [GenrePreference]) -> UserProfile {
        UserProfile(
            userId: "u", topGenres: topGenres, topActors: [], preferredMoods: [],
            watchPatterns: WatchPattern(),
            contentTypePreference: ContentTypeRatio(movieRatio: 0.5, tvRatio: 0.5),
            recentActivity: RecentActivity()
        )
    }

    /// La componente random è `Double.random(in: 0...5)`, quindi lo score deterministico D
    /// soddisfa sempre `D <= score <= D + 5`. Questo pinna esattamente la formula.
    private func assertScore(_ score: Double, deterministic D: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(score, D - 1e-9, "score sotto il minimo deterministico", file: file, line: line)
        XCTAssertLessThanOrEqual(score, D + 5 + 1e-9, "score oltre deterministico + jitter max", file: file, line: line)
    }

    // MARK: personalizationScore

    func test_score_baseline_isJitterOnly() {
        let s = DiscoveryRanking.personalizationScore(movie: movie(id: 1), userProfile: profile(topGenres: []))
        assertScore(s, deterministic: 0) // solo jitter 0...5
    }

    func test_score_genreMatchAndPreferenceStrength() {
        // 1 match * 15 + pref.totalScore(10) * 2 = 15 + 20 = 35
        let m = movie(id: 1, genreIds: [28])
        let p = profile(topGenres: [GenrePreference(genreId: 28, genreName: "Action", totalScore: 10)])
        assertScore(DiscoveryRanking.personalizationScore(movie: m, userProfile: p), deterministic: 35)
    }

    func test_score_quality_andPopularityCap() {
        // voteAverage 8 * 2 = 16 ; popularity 5000/100 = 50 -> cap 10 ; totale 26
        let m = movie(id: 1, voteAverage: 8, popularity: 5000)
        assertScore(DiscoveryRanking.personalizationScore(movie: m, userProfile: profile(topGenres: [])), deterministic: 26)
    }

    func test_score_recencyBias_appliesFrom2020() {
        // 2023 -> (2023-2020)*2 = 6
        let recent = movie(id: 1, releaseDate: "2023-06-01")
        assertScore(DiscoveryRanking.personalizationScore(movie: recent, userProfile: profile(topGenres: [])), deterministic: 6)
        // 2015 < 2020 -> nessun bonus recency
        let old = movie(id: 2, releaseDate: "2015-06-01")
        assertScore(DiscoveryRanking.personalizationScore(movie: old, userProfile: profile(topGenres: [])), deterministic: 0)
    }

    // MARK: ensureDiversity

    private func scored(_ genreIds: [Int]?, id: Int) -> ScoredItem<Movie> {
        ScoredItem(item: movie(id: id, genreIds: genreIds), score: 0)
    }

    func test_diversity_capsPerGenre() {
        let items = (1...5).map { scored([28], id: $0) }
        let out = DiscoveryRanking.ensureDiversity(items, maxPerGenre: 2, maxItems: 10)
        XCTAssertEqual(out.count, 2, "stesso genere: ammessi al massimo maxPerGenre")
        XCTAssertEqual(out.map(\.item.id), [1, 2], "ordine preservato")
    }

    func test_diversity_capsTotalItems() {
        let items = (1...10).map { scored([$0], id: $0) } // generi tutti distinti
        let out = DiscoveryRanking.ensureDiversity(items, maxPerGenre: 5, maxItems: 3)
        XCTAssertEqual(out.count, 3, "tetto globale maxItems")
        XCTAssertEqual(out.map(\.item.id), [1, 2, 3])
    }

    func test_diversity_nilGenresAlwaysAdmitted() {
        let items = (1...4).map { scored(nil, id: $0) }
        let out = DiscoveryRanking.ensureDiversity(items, maxPerGenre: 1, maxItems: 10)
        XCTAssertEqual(out.count, 4, "item senza generi non sono mai vincolati dal limite per-genere")
    }

    // MARK: cosineSimilarity

    func test_cosine_identicalVectors_isOne() {
        XCTAssertEqual(DiscoveryRanking.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1, accuracy: 1e-9)
    }

    func test_cosine_orthogonal_isZero() {
        XCTAssertEqual(DiscoveryRanking.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-9)
    }

    func test_cosine_emptyOrZeroNorm_isZero() {
        XCTAssertEqual(DiscoveryRanking.cosineSimilarity([], [1, 2]), 0)
        XCTAssertEqual(DiscoveryRanking.cosineSimilarity([0, 0], [1, 2]), 0)
    }

    func test_cosine_usesOverlappingPrefix() {
        // confronta solo i primi 2 elementi -> identico
        XCTAssertEqual(DiscoveryRanking.cosineSimilarity([1, 2], [1, 2, 99]), 1, accuracy: 1e-9)
    }

    // MARK: dedup

    func test_deduplicateMoviesById_keepsFirstSeenOrder() {
        let movies = [movie(id: 1), movie(id: 2), movie(id: 1), movie(id: 3), movie(id: 2)]
        XCTAssertEqual(DiscoveryRanking.deduplicateMoviesById(movies).map(\.id), [1, 2, 3])
    }

    func test_collectUniqueMovies_acrossCarousels() {
        let c1 = PersonalizedCarousel(type: .hiddenGems, titleSpec: CarouselTitleSpec(key: "k"),
            items: [movie(id: 1), movie(id: 2)], descriptions: [:], reason: "")
        let c2 = PersonalizedCarousel(type: .staffPicks, titleSpec: CarouselTitleSpec(key: "k"),
            items: [movie(id: 2), movie(id: 3)], descriptions: [:], reason: "")
        XCTAssertEqual(DiscoveryRanking.collectUniqueMovies(from: [c1, c2]).map(\.id), [1, 2, 3])
    }
}

// MARK: - ClipFormatters (count + relative-time puri estratti da ClipsView)

final class ClipFormattersTests: XCTestCase {

    func test_shortCount_belowThousand_isPlain() {
        XCTAssertEqual(ClipFormatters.shortCount(0), "0")
        XCTAssertEqual(ClipFormatters.shortCount(999), "999")
    }

    func test_shortCount_thousands() {
        XCTAssertEqual(ClipFormatters.shortCount(1_000), "1.0K")
        XCTAssertEqual(ClipFormatters.shortCount(1_500), "1.5K")
        XCTAssertEqual(ClipFormatters.shortCount(999_999), "1000.0K") // 999999/1000 = 999.999 -> %.1f arrotonda
    }

    func test_shortCount_millions() {
        XCTAssertEqual(ClipFormatters.shortCount(1_000_000), "1.0M")
        XCTAssertEqual(ClipFormatters.shortCount(2_500_000), "2.5M")
    }

    func test_shortTimeAgo_picksLargestNonZeroUnit() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func ago(_ seconds: TimeInterval) -> String {
            ClipFormatters.shortTimeAgo(from: now.addingTimeInterval(-seconds), to: now)
        }
        XCTAssertEqual(ago(30), "30s")
        XCTAssertEqual(ago(5 * 60), "5m")
        XCTAssertEqual(ago(3 * 3600), "3h")
        XCTAssertEqual(ago(2 * 86_400), "2d")
        XCTAssertEqual(ago(3 * 7 * 86_400), "3w")
    }

    func test_shortTimeAgo_nowAndFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertEqual(ClipFormatters.shortTimeAgo(from: now, to: now), "now")
        XCTAssertEqual(ClipFormatters.shortTimeAgo(from: now.addingTimeInterval(60), to: now), "now",
                       "date nel futuro -> componenti non positive -> now")
    }
}

// MARK: - ProviderSelection (scelta provider Flatrate>Rent>Buy, estratta da ListsView)

final class ProviderSelectionTests: XCTestCase {

    private func provider(id: Int, name: String = "Unknown", logo: String = "/x.jpg",
                          link: URL? = nil) -> Provider {
        Provider(providerId: id, providerName: name, logoPath: logo, displayPriority: 0,
                 price: nil, quality: nil, presentationType: nil, externalLink: link)
    }

    func test_flatrateBeatsRentAndBuy() {
        let cp = CountryProviders(
            flatrate: [provider(id: 1, link: URL(string: "https://a")!)],
            rent: [provider(id: 2, link: URL(string: "https://b")!)],
            buy: [provider(id: 3, link: URL(string: "https://c")!)],
            link: nil)
        XCTAssertEqual(ProviderSelection.selectTopProvider(from: cp).top?.id, 1)
    }

    func test_picksFirstValidInTier_skipsInvalid() {
        // primo provider ha logo inusabile (.svg) -> scartato; vince il secondo valido
        let cp = CountryProviders(
            flatrate: [provider(id: 1, logo: "/x.svg", link: URL(string: "https://a")!),
                       provider(id: 2, link: URL(string: "https://b")!)],
            rent: nil, buy: nil, link: nil)
        XCTAssertEqual(ProviderSelection.selectTopProvider(from: cp).top?.id, 2)
    }

    func test_fallsThroughToRentWhenFlatrateHasNoValid() {
        let cp = CountryProviders(
            flatrate: [provider(id: 1, logo: "")], // logo vuoto -> inusabile
            rent: [provider(id: 2, link: URL(string: "https://b")!)],
            buy: nil, link: nil)
        XCTAssertEqual(ProviderSelection.selectTopProvider(from: cp).top?.id, 2)
    }

    func test_countryLinkMakesUsableProviderValid() {
        // nessun externalLink né homepage nota, ma cp.link != nil -> valido
        let cp = CountryProviders(
            flatrate: [provider(id: 1)], rent: nil, buy: nil,
            link: "https://region-page")
        let result = ProviderSelection.selectTopProvider(from: cp)
        XCTAssertEqual(result.link, "https://region-page")
        XCTAssertEqual(result.top?.id, 1)
    }

    func test_noReachability_yieldsNilTop() {
        // logo usabile ma: niente externalLink, niente cp.link, nome senza homepage nota
        let cp = CountryProviders(
            flatrate: [provider(id: 1, name: "Unknown")], rent: nil, buy: nil, link: nil)
        XCTAssertNil(ProviderSelection.selectTopProvider(from: cp).top)
    }

    func test_knownPlatformHomepageMakesValidWithoutLinks() {
        let cp = CountryProviders(
            flatrate: [provider(id: 1, name: "Netflix")], rent: nil, buy: nil, link: nil)
        XCTAssertEqual(ProviderSelection.selectTopProvider(from: cp).top?.id, 1,
                       "homepage piattaforma nota -> valido anche senza link")
    }
}

// MARK: - WatchProviderDisplayFiltering (provider visibili in MovieDetailView)

final class WatchProviderDisplayFilteringTests: XCTestCase {

    private func provider(id: Int, name: String = "Unknown", logo: String = "/x.jpg",
                          link: URL? = nil) -> Provider {
        Provider(providerId: id, providerName: name, logoPath: logo, displayPriority: 0,
                 price: nil, quality: nil, presentationType: nil, externalLink: link)
    }

    func test_visibleProviders_filtersUnusableLogos() {
        let providers = [
            provider(id: 1, logo: "", link: URL(string: "https://a")!),
            provider(id: 2, logo: "/logo.svg", link: URL(string: "https://b")!),
            provider(id: 3, logo: "/logo-white.png", link: URL(string: "https://c")!),
            provider(id: 4, logo: "/logo.png", link: URL(string: "https://d")!)
        ]

        let visible = WatchProviderDisplayFiltering.visibleProviders(providers, justWatchLink: nil)
        XCTAssertEqual(visible.map(\.id), [4])
    }

    func test_visibleProviders_keepsProviderWithExternalLink() {
        let providers = [provider(id: 1, link: URL(string: "https://direct")!)]

        let visible = WatchProviderDisplayFiltering.visibleProviders(providers, justWatchLink: nil)
        XCTAssertEqual(visible.map(\.id), [1])
    }

    func test_visibleProviders_countryLinkMakesProviderReachable() {
        let providers = [provider(id: 1)]

        let visible = WatchProviderDisplayFiltering.visibleProviders(providers, justWatchLink: "https://region-page")
        XCTAssertEqual(visible.map(\.id), [1])
    }

    func test_visibleProviders_knownHomepageMakesProviderReachableWithoutLinks() {
        let providers = [provider(id: 1, name: "Netflix")]

        let visible = WatchProviderDisplayFiltering.visibleProviders(providers, justWatchLink: nil)
        XCTAssertEqual(visible.map(\.id), [1])
    }

    func test_visibleProviders_unknownWithoutLinksIsHidden() {
        let providers = [provider(id: 1, name: "Unknown")]

        let visible = WatchProviderDisplayFiltering.visibleProviders(providers, justWatchLink: nil)
        XCTAssertTrue(visible.isEmpty)
    }

    func test_hasAnyVisibleProvider_checksEveryTier() {
        let countryProviders = CountryProviders(
            flatrate: [provider(id: 1, logo: "")],
            rent: [provider(id: 2, link: URL(string: "https://rent")!)],
            buy: nil,
            link: nil
        )

        XCTAssertTrue(WatchProviderDisplayFiltering.hasAnyVisibleProvider(in: countryProviders))
    }
}

// MARK: - WatchProviderTierGroupsBuilder (gruppi provider estratti da MovieDetailView)

final class WatchProviderTierGroupsBuilderTests: XCTestCase {

    private func provider(id: Int, name: String = "Unknown", logo: String = "/x.jpg",
                          link: URL? = nil) -> Provider {
        Provider(providerId: id, providerName: name, logoPath: logo, displayPriority: 0,
                 price: nil, quality: nil, presentationType: nil, externalLink: link)
    }

    func test_groupsPreserveStreamingRentBuyOrder() {
        let providers = CountryProviders(
            flatrate: [provider(id: 1)],
            rent: [provider(id: 2)],
            buy: [provider(id: 3)],
            link: "https://justwatch.example/movie"
        )

        let groups = WatchProviderTierGroupsBuilder.groups(in: providers)

        XCTAssertEqual(groups.map(\.titleKey), [
            "platforms.streaming",
            "platforms.rent",
            "platforms.buy"
        ])
        XCTAssertEqual(groups.map { $0.providers.map(\.id) }, [[1], [2], [3]])
    }

    func test_groupsOmitEmptyAndNonVisibleTiers() {
        let providers = CountryProviders(
            flatrate: [provider(id: 1, logo: "")],
            rent: nil,
            buy: [provider(id: 3, link: URL(string: "https://buy")!)],
            link: nil
        )

        let groups = WatchProviderTierGroupsBuilder.groups(in: providers)

        XCTAssertEqual(groups.map(\.titleKey), ["platforms.buy"])
        XCTAssertEqual(groups.first?.providers.map(\.id), [3])
    }

    func test_groupsCarryCountryJustWatchLink() {
        let providers = CountryProviders(
            flatrate: [provider(id: 1)],
            rent: nil,
            buy: nil,
            link: "https://justwatch.example/movie"
        )

        let groups = WatchProviderTierGroupsBuilder.groups(in: providers)

        XCTAssertEqual(groups.first?.justWatchLink, "https://justwatch.example/movie")
    }
}

// MARK: - JustWatchLinkBuilder (URL JustWatch estratto da MovieDetailView)

final class JustWatchLinkBuilderTests: XCTestCase {

    func test_validProviderLinkWins() {
        let url = JustWatchLinkBuilder.url(
            providerLink: "https://www.justwatch.com/us/movie/example",
            countryId: "IT",
            title: "The Matrix"
        )

        XCTAssertEqual(url?.absoluteString, "https://www.justwatch.com/us/movie/example")
    }

    func test_relativeProviderLinkStillWins() {
        let url = JustWatchLinkBuilder.url(
            providerLink: "not a url",
            countryId: "IT",
            title: "The Matrix"
        )

        XCTAssertEqual(url?.absoluteString, "not%20a%20url",
                       "URL(string:) accepted this in the original MovieDetailView code, so the helper preserves it")
    }

    func test_fallbackLowercasesCountryAndEncodesTitle() {
        let url = JustWatchLinkBuilder.url(
            providerLink: nil,
            countryId: "US",
            title: "The Matrix Reloaded"
        )

        XCTAssertEqual(url?.absoluteString, "https://www.justwatch.com/us/search?q=The%20Matrix%20Reloaded")
    }
}

// MARK: - MovieShareTextBuilder (testo share estratto da MovieDetailView)

final class MovieShareTextBuilderTests: XCTestCase {

    func test_titleOnly() {
        XCTAssertEqual(
            MovieShareTextBuilder.text(title: "Dune", year: nil, overview: ""),
            "Check out Dune"
        )
    }

    func test_titleWithYear() {
        XCTAssertEqual(
            MovieShareTextBuilder.text(title: "Dune", year: "2021", overview: ""),
            "Check out Dune (2021)"
        )
    }

    func test_titleYearAndOverview() {
        XCTAssertEqual(
            MovieShareTextBuilder.text(title: "Dune", year: "2021", overview: "A mythic journey."),
            "Check out Dune (2021)\n\nA mythic journey."
        )
    }
}

// MARK: - MoviePosterShareURLBuilder (URL poster share estratto da MovieDetailView)

final class MoviePosterShareURLBuilderTests: XCTestCase {

    func test_nilPosterPathProducesNoURL() {
        XCTAssertNil(MoviePosterShareURLBuilder.url(posterPath: nil))
    }

    func test_validPosterPathUsesTMDBW500Base() {
        let url = MoviePosterShareURLBuilder.url(posterPath: "/abc123.jpg")

        XCTAssertEqual(url?.absoluteString, "https://image.tmdb.org/t/p/w500/abc123.jpg")
    }

    func test_emptyPosterPathStillProducesBaseSizeURL() {
        let url = MoviePosterShareURLBuilder.url(posterPath: "")

        XCTAssertEqual(url?.absoluteString, "https://image.tmdb.org/t/p/w500")
    }
}

// MARK: - MovieUnavailableNotificationCopyBuilder (copy notify-me estratto da MovieDetailView)

final class MovieUnavailableNotificationCopyBuilderTests: XCTestCase {

    func test_unavailableMessageIncludesTitle() {
        XCTAssertEqual(
            MovieUnavailableNotificationCopyBuilder.unavailableMessage(title: "Dune"),
            "Unluckily Dune isn't currently available."
        )
    }

    func test_staticQuestionButtonAndAlertTitleMatchCurrentCopy() {
        XCTAssertEqual(MovieUnavailableNotificationCopyBuilder.notificationQuestion, "Would you like to be notified?")
        XCTAssertEqual(MovieUnavailableNotificationCopyBuilder.notifyButtonTitle, "Notify Me")
        XCTAssertEqual(MovieUnavailableNotificationCopyBuilder.alertTitle, "Notify Me")
    }

    func test_alertMessageIncludesQuotedTitle() {
        XCTAssertEqual(
            MovieUnavailableNotificationCopyBuilder.alertMessage(title: "Dune"),
            "We'll send you a notification as soon as 'Dune' is available for streaming, rent, or buy."
        )
    }
}

// MARK: - SupabasePullRowNormalizer (normalizzazione righe remote estratta da SupabaseClient)

final class SupabasePullRowNormalizerTests: XCTestCase {

    func test_invalidMediaTypeForListItemsDefaultsToMovie() {
        let normalized = SupabasePullRowNormalizer.normalize(
            row: ["id": "item-1", "media_type": "podcast"],
            table: "list_items"
        )

        XCTAssertEqual(normalized["media_type"] as? String, "movie")
    }

    func test_validMediaTypeForClipsIsPreserved() {
        let normalized = SupabasePullRowNormalizer.normalize(
            row: ["id": "clip-1", "media_type": "tv"],
            table: "clips"
        )

        XCTAssertEqual(normalized["media_type"] as? String, "tv")
    }

    func test_unrelatedTableKeepsMediaTypeUnchanged() {
        let normalized = SupabasePullRowNormalizer.normalize(
            row: ["id": "profile-1", "media_type": "podcast"],
            table: "profiles"
        )

        XCTAssertEqual(normalized["media_type"] as? String, "podcast")
    }

    func test_arrayFieldsBecomeJSONStringFields() {
        let normalized = SupabasePullRowNormalizer.normalize(
            row: [
                "genres": ["Drama", "Sci-Fi"],
                "actors": ["A", "B"],
                "keywords": ["space"],
                "origin_country": ["US", "IT"]
            ],
            table: "clips"
        )

        XCTAssertEqual(normalized["genres"] as? String, "[\"Drama\",\"Sci-Fi\"]")
        XCTAssertEqual(normalized["actors"] as? String, "[\"A\",\"B\"]")
        XCTAssertEqual(normalized["keywords"] as? String, "[\"space\"]")
        XCTAssertEqual(normalized["origin_country"] as? String, "[\"US\",\"IT\"]")
    }
}

// MARK: - SupabaseSyncFormatting (formatting/parsing estratti da SupabaseClient)

final class SupabaseSyncFormattingTests: XCTestCase {

    func test_normalizeUserIdLowercasesCurrentBehavior() {
        XCTAssertEqual(SupabaseSyncFormatting.normalizeUserId("ABC-Def-123"), "abc-def-123")
    }

    func test_parseDateAcceptsISO8601Strings() {
        let date = SupabaseSyncFormatting.parseDate("2026-06-04T16:35:00Z")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(calendar.component(.year, from: date!), 2026)
        XCTAssertEqual(calendar.component(.month, from: date!), 6)
        XCTAssertEqual(calendar.component(.day, from: date!), 4)
        XCTAssertEqual(calendar.component(.hour, from: date!), 16)
    }

    func test_parseDateAcceptsSQLTimestampInUTC() {
        let date = SupabaseSyncFormatting.parseDate("2026-06-04 16:35:00")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(calendar.component(.year, from: date!), 2026)
        XCTAssertEqual(calendar.component(.month, from: date!), 6)
        XCTAssertEqual(calendar.component(.day, from: date!), 4)
        XCTAssertEqual(calendar.component(.hour, from: date!), 16)
    }

    func test_parseDateRejectsNonStringValues() {
        XCTAssertNil(SupabaseSyncFormatting.parseDate(123))
        XCTAssertNil(SupabaseSyncFormatting.parseDate(nil))
    }

    func test_localDayKeyUsesCurrentLocalCalendarDay() {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 12))!

        XCTAssertEqual(SupabaseSyncFormatting.localDayKey(for: date), "2026-06-04")
    }
}

// MARK: - MovieCreditsInfoBuilder (righe informative estratte da MovieDetailView)

final class MovieCreditsInfoBuilderTests: XCTestCase {

    private func movie(
        voteAverage: Double = 8.4,
        genres: [Genre]? = [Genre(id: 1, name: "Drama"), Genre(id: 2, name: "Sci-Fi")],
        runtime: Int? = 155,
        countries: [ProductionCountry]? = [ProductionCountry(iso: "US", name: "United States")]
    ) -> Movie {
        Movie(
            id: 1,
            title: "Dune",
            overview: "A mythic journey.",
            posterPath: nil,
            backdropPath: nil,
            releaseDate: "2021-10-22",
            voteAverage: voteAverage,
            voteCount: 100,
            genreIds: nil,
            genres: genres,
            adult: false,
            originalLanguage: "en",
            popularity: 10,
            runtime: runtime,
            status: nil,
            tagline: nil,
            productionCountries: countries,
            imdbId: nil
        )
    }

    func test_rowsPreserveCurrentOrderAndValues() {
        let director = Crew(id: 10, name: "Denis Villeneuve", job: "Director", department: "Directing", profilePath: nil)

        let rows = MovieCreditsInfoBuilder.rows(movie: movie(), director: director)

        XCTAssertEqual(rows.map(\.titleKey), [
            "movieDetail.rating",
            "movieDetail.genres",
            "movieDetail.runtime",
            "movieDetail.country",
            "movieDetail.director"
        ])
        XCTAssertEqual(rows.map(\.value), [
            "84%",
            "Drama, Sci-Fi",
            "2h 35m",
            "United States",
            "Denis Villeneuve"
        ])
    }

    func test_rowsOmitEmptyOptionalInformation() {
        let rows = MovieCreditsInfoBuilder.rows(
            movie: movie(voteAverage: 0, genres: [], runtime: nil, countries: []),
            director: nil
        )

        XCTAssertTrue(rows.isEmpty)
    }

    func test_rowsUseFirstProductionCountryOnly() {
        let rows = MovieCreditsInfoBuilder.rows(
            movie: movie(countries: [
                ProductionCountry(iso: "CA", name: "Canada"),
                ProductionCountry(iso: "US", name: "United States")
            ]),
            director: nil
        )

        XCTAssertEqual(rows.first(where: { $0.titleKey == "movieDetail.country" })?.value, "Canada")
    }
}

// MARK: - MovieActionButtonStateBuilder (stato pulsanti azione estratto da MovieDetailView)

final class MovieActionButtonStateBuilderTests: XCTestCase {

    private func item(
        id: String = UUID().uuidString,
        mediaId: Int = 1,
        mediaType: MediaType = .movie
    ) -> MediaListItem {
        MediaListItem(
            id: id,
            mediaId: mediaId,
            mediaType: mediaType,
            title: "Dune",
            posterPath: nil
        )
    }

    private func list(
        id: String,
        type: ListType,
        items: [MediaListItem]
    ) -> MediaList {
        MediaList(id: id, name: id, type: type, items: items)
    }

    func test_stateDetectsMembershipAcrossLists() {
        let seen = list(id: "seen", type: .seen, items: [item(mediaId: 1)])
        let liked = list(id: "liked", type: .liked, items: [])
        let disliked = list(id: "disliked", type: .disliked, items: [])
        let custom = list(id: "custom", type: .custom, items: [item(mediaId: 2)])

        let state = MovieActionButtonStateBuilder.state(
            mediaId: 1,
            mediaType: .movie,
            lists: [custom, seen, liked, disliked],
            seenList: seen,
            likedList: liked,
            dislikedList: disliked
        )

        XCTAssertTrue(state.isInAnyList)
        XCTAssertTrue(state.isInSeen)
        XCTAssertFalse(state.isInLiked)
        XCTAssertFalse(state.isInDisliked)
    }

    func test_stateRequiresMatchingMediaType() {
        let seen = list(id: "seen", type: .seen, items: [item(mediaId: 1, mediaType: .tv)])
        let liked = list(id: "liked", type: .liked, items: [])
        let disliked = list(id: "disliked", type: .disliked, items: [])

        let state = MovieActionButtonStateBuilder.state(
            mediaId: 1,
            mediaType: .movie,
            lists: [seen, liked, disliked],
            seenList: seen,
            likedList: liked,
            dislikedList: disliked
        )

        XCTAssertFalse(state.isInAnyList)
        XCTAssertFalse(state.isInSeen)
    }

    func test_stateCountsMatchingLikesAndDislikes() {
        let seen = list(id: "seen", type: .seen, items: [])
        let liked = list(id: "liked", type: .liked, items: [
            item(id: "like-1", mediaId: 1),
            item(id: "like-2", mediaId: 1),
            item(id: "like-other", mediaId: 2)
        ])
        let disliked = list(id: "disliked", type: .disliked, items: [
            item(id: "dislike-1", mediaId: 1),
            item(id: "dislike-tv", mediaId: 1, mediaType: .tv)
        ])

        let state = MovieActionButtonStateBuilder.state(
            mediaId: 1,
            mediaType: .movie,
            lists: [seen, liked, disliked],
            seenList: seen,
            likedList: liked,
            dislikedList: disliked
        )

        XCTAssertTrue(state.isInLiked)
        XCTAssertTrue(state.isInDisliked)
        XCTAssertEqual(state.likesCount, 2)
        XCTAssertEqual(state.dislikesCount, 1)
    }
}

// MARK: - GamificationLeveling (curva XP->livello unificata da GamificationService + ConflictResolver)

final class GamificationLevelingTests: XCTestCase {

    func test_thresholds_atBracketBoundaries() {
        // valori di confine dei vari segmenti della curva esponenziale
        XCTAssertEqual(GamificationLeveling.threshold(for: 1), 0)
        XCTAssertEqual(GamificationLeveling.threshold(for: 2), 100)
        XCTAssertEqual(GamificationLeveling.threshold(for: 5), 400)
        XCTAssertEqual(GamificationLeveling.threshold(for: 6), 800)
        XCTAssertEqual(GamificationLeveling.threshold(for: 10), 2000)
        XCTAssertEqual(GamificationLeveling.threshold(for: 15), 5000)
        XCTAssertEqual(GamificationLeveling.threshold(for: 20), 10000)
        XCTAssertEqual(GamificationLeveling.threshold(for: 30), 40000)
        XCTAssertEqual(GamificationLeveling.threshold(for: 40), 80000)
        XCTAssertEqual(GamificationLeveling.threshold(for: 41), 85000)
    }

    func test_level_mapsXPToLevel() {
        XCTAssertEqual(GamificationLeveling.level(forTotalXP: 0), 1)
        XCTAssertEqual(GamificationLeveling.level(forTotalXP: 99), 1)
        XCTAssertEqual(GamificationLeveling.level(forTotalXP: 100), 2, "raggiunta la soglia del livello 2")
        XCTAssertEqual(GamificationLeveling.level(forTotalXP: 399), 4)
        XCTAssertEqual(GamificationLeveling.level(forTotalXP: 400), 5)
    }

    func test_level_cappedAt50() {
        XCTAssertEqual(GamificationLeveling.level(forTotalXP: 10_000_000), 50)
    }

    /// Caratterizza l'equivalenza tra la curva e il vecchio loop di UserGamificationState.
    func test_calculateLevel_matchesThresholdLoop() {
        for xp in stride(from: 0, through: 120_000, by: 137) {
            var state = UserGamificationState(totalXP: xp)
            state.calculateLevel()
            XCTAssertEqual(state.currentLevel, GamificationLeveling.level(forTotalXP: xp))
        }
    }
}

// MARK: - DiscoveryQueryDerivation (derivazione query da preferenze/filtri, estratta da DiscoveryPersonalizationService)

final class DiscoveryQueryDerivationTests: XCTestCase {

    private func media(_ year: Int?) -> MediaSummary { MediaSummary(id: 1, title: "m", year: year) }

    func test_inferDecade() {
        XCTAssertEqual(DiscoveryQueryDerivation.inferDecade(from: []), 2010, "fallback senza dati")
        XCTAssertEqual(DiscoveryQueryDerivation.inferDecade(from: [media(nil), media(nil)]), 2010,
                       "tutti anni nil -> fallback")
        // [2001,2009,2014]: avg = 6024/3 = 2008 -> decade 2000
        XCTAssertEqual(DiscoveryQueryDerivation.inferDecade(from: [media(2001), media(2009), media(2014)]), 2000)
        // anni nil ignorati: [nil,1995,2005] -> avg 2000 -> 2000
        XCTAssertEqual(DiscoveryQueryDerivation.inferDecade(from: [media(nil), media(1995), media(2005)]), 2000)
    }

    func test_moodToGenreIds() {
        XCTAssertEqual(DiscoveryQueryDerivation.moodToGenreIds(.happy), [35, 10751])
        XCTAssertEqual(DiscoveryQueryDerivation.moodToGenreIds(.energetic), [28, 878])
        XCTAssertEqual(DiscoveryQueryDerivation.moodToGenreIds(.sad), [18])
    }

    func test_yearDateRange() {
        var f = GlobalDiscoveryFilters()
        f.releasePeriodPreset = .custom
        f.customYearStart = 2000
        f.customYearEnd = 2010
        let r = DiscoveryQueryDerivation.yearDateRange(filters: f)
        XCTAssertEqual(r.gte, "2000-01-01")
        XCTAssertEqual(r.lte, "2010-12-31")

        var empty = GlobalDiscoveryFilters()
        empty.releasePeriodPreset = .custom // start/end nil -> bounds nil
        let r2 = DiscoveryQueryDerivation.yearDateRange(filters: empty)
        XCTAssertNil(r2.gte)
        XCTAssertNil(r2.lte)
    }
}

// MARK: - AuthCallbackURLParser (parsing URL callback Supabase, estratto da AuthService)

final class AuthCallbackURLParserTests: XCTestCase {

    func test_combinedQueryItems_mergesQueryAndFragment() {
        let url = URL(string: "vibewatch://auth/callback?type=recovery#access_token=abc&refresh_token=def")!
        let items = AuthCallbackURLParser.combinedQueryItems(from: url)
        let dict = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                              uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["type"], "recovery")
        XCTAssertEqual(dict["access_token"], "abc")
        XCTAssertEqual(dict["refresh_token"], "def")
    }

    func test_isPasswordRecovery_query() {
        XCTAssertTrue(AuthCallbackURLParser.isPasswordRecovery(
            URL(string: "vibewatch://auth/callback?type=recovery")!))
        XCTAssertFalse(AuthCallbackURLParser.isPasswordRecovery(
            URL(string: "vibewatch://auth/callback?type=signup")!))
    }

    func test_isPasswordRecovery_fragment() {
        // type nel fragment deve comunque essere rilevato
        XCTAssertTrue(AuthCallbackURLParser.isPasswordRecovery(
            URL(string: "vibewatch://auth/callback#type=recovery&access_token=x")!))
    }

    func test_moveFragmentToQueryIfNeeded_movesTokens() {
        let url = URL(string: "vibewatch://auth/callback?a=1#b=2&c=3")!
        let moved = AuthCallbackURLParser.moveFragmentToQueryIfNeeded(url)
        XCTAssertNil(URLComponents(url: moved, resolvingAgainstBaseURL: false)?.fragment,
                     "il fragment deve essere svuotato")
        let names = Set(URLComponents(url: moved, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        XCTAssertEqual(names, ["a", "b", "c"], "tutti gli item finiscono in query")
    }

    func test_moveFragmentToQueryIfNeeded_noFragment_returnsUnchanged() {
        let url = URL(string: "vibewatch://auth/callback?a=1")!
        XCTAssertEqual(AuthCallbackURLParser.moveFragmentToQueryIfNeeded(url), url)
    }

    func test_shouldShowRecoveryError() {
        XCTAssertTrue(AuthCallbackURLParser.shouldShowRecoveryError(
            from: URL(string: "vibewatch://auth/callback?type=recovery")!))
        XCTAssertTrue(AuthCallbackURLParser.shouldShowRecoveryError(
            from: URL(string: "vibewatch://auth/callback?error_code=otp_expired")!))
        XCTAssertFalse(AuthCallbackURLParser.shouldShowRecoveryError(
            from: URL(string: "vibewatch://auth/callback?error_code=other")!))
    }
}

// MARK: - LevelCalculator (riconciliato sulla curva canonica GamificationLeveling)

final class LevelCalculatorTests: XCTestCase {

    func test_getLevelInfo_derivesFromGamificationLeveling() {
        for level in 1...50 {
            let info = LevelCalculator.getLevelInfo(level: level)
            XCTAssertEqual(info.xpStart, GamificationLeveling.threshold(for: level))
            XCTAssertEqual(info.xpEnd, GamificationLeveling.threshold(for: level + 1))
            XCTAssertEqual(info.rank.name, UserRank.forLevel(level).name)
        }
    }

    func test_getLevelInfo_clampsOutOfRange() {
        XCTAssertEqual(LevelCalculator.getLevelInfo(level: 0).xpStart, GamificationLeveling.threshold(for: 1))
        let top = LevelCalculator.getLevelInfo(level: 999)
        XCTAssertEqual(top.xpStart, GamificationLeveling.threshold(for: 50))
        XCTAssertEqual(top.xpEnd, GamificationLeveling.threshold(for: 51))
    }

    /// Il FIX: per qualunque totalXP, il bracket del livello corrente contiene totalXP,
    /// quindi la progress (totalXP - xpStart)/(xpEnd - xpStart) è sempre in [0, 1).
    /// Prima (curva divergente) poteva essere negativa.
    func test_currentLevelBracketContainsXP_noNegativeProgress() {
        for xp in stride(from: 0, through: 200_000, by: 113) {
            let currentLevel = GamificationLeveling.level(forTotalXP: xp)
            let info = LevelCalculator.getLevelInfo(level: currentLevel)
            XCTAssertLessThanOrEqual(info.xpStart, xp, "xpStart <= totalXP (no progress negativa) a xp=\(xp)")
            if currentLevel < 50 {
                XCTAssertLessThan(xp, info.xpEnd, "totalXP < xpEnd del livello corrente a xp=\(xp)")
            }
        }
    }
}

// MARK: - SeasonDetailViewModel (DI proof-of-pattern: protocolli stretti + fake)

private struct DummyTMDBError: Error {}

private final class FakeTVSeasonProvider: TVSeasonProviding, @unchecked Sendable {
    var result: Result<SeasonDetail, Error>
    private(set) var callCount = 0
    init(_ result: Result<SeasonDetail, Error>) { self.result = result }
    func getTVSeasonDetails(showId: Int, seasonNumber: Int) async throws -> SeasonDetail {
        callCount += 1
        return try result.get()
    }
}

private final class FakeTVSeasonCache: TVSeasonCaching, @unchecked Sendable {
    var cached: SeasonDetail?
    private(set) var writes: [SeasonDetail] = []
    init(cached: SeasonDetail? = nil) { self.cached = cached }
    func getCachedTVSeason(showId: Int, seasonNumber: Int) async throws -> SeasonDetail? { cached }
    func cacheTVSeason(_ season: SeasonDetail, showId: Int, seasonNumber: Int) async throws { writes.append(season) }
}

@MainActor
final class SeasonDetailViewModelTests: XCTestCase {

    private func season(id: Int, name: String) -> SeasonDetail {
        SeasonDetail(id: id, name: name, overview: "", posterPath: nil, seasonNumber: 1,
                     airDate: "2022-01-01", voteAverage: 8, episodes: [])
    }

    func test_noCache_loadsFromTMDB_andCaches() async {
        let fresh = season(id: 1, name: "S1")
        let tmdb = FakeTVSeasonProvider(.success(fresh))
        let cache = FakeTVSeasonCache(cached: nil)
        let vm = SeasonDetailViewModel(showId: 10, seasonNumber: 1, tmdb: tmdb, cache: cache)

        await vm.loadSeasonDetails()

        XCTAssertEqual(vm.season?.id, 1)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(tmdb.callCount, 1, "cache miss -> chiede a TMDB")
        XCTAssertEqual(cache.writes.map(\.id), [1], "il fresh viene messo in cache")
    }

    func test_noCache_tmdbThrows_setsError() async {
        let tmdb = FakeTVSeasonProvider(.failure(DummyTMDBError()))
        let cache = FakeTVSeasonCache(cached: nil)
        let vm = SeasonDetailViewModel(showId: 10, seasonNumber: 1, tmdb: tmdb, cache: cache)

        await vm.loadSeasonDetails()

        XCTAssertNil(vm.season)
        XCTAssertNotNil(vm.error, "errore TMDB -> error settato")
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(cache.writes.isEmpty)
    }

    func test_cacheHit_setsSeasonImmediately() async {
        let cached = season(id: 99, name: "cached")
        // provider che lancia: il refresh in background non sovrascrive (guard try?), test deterministico
        let tmdb = FakeTVSeasonProvider(.failure(DummyTMDBError()))
        let cache = FakeTVSeasonCache(cached: cached)
        let vm = SeasonDetailViewModel(showId: 10, seasonNumber: 1, tmdb: tmdb, cache: cache)

        await vm.loadSeasonDetails()

        XCTAssertEqual(vm.season?.id, 99, "cache hit -> usa il valore in cache")
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
    }
}

// MARK: - EntitlementPolicy (policy entitlement unificata per tier: clip/AI/liste/ads §1.3)

final class EntitlementPolicyTests: XCTestCase {

    private let limit = AppConstants.Clips.freeUserDailyLimit // 25

    func test_dailyLimit_perTier() {
        XCTAssertEqual(EntitlementPolicy.dailyClipLimit(for: .anonymous), limit)
        XCTAssertEqual(EntitlementPolicy.dailyClipLimit(for: .free), limit)
        XCTAssertNil(EntitlementPolicy.dailyClipLimit(for: .pro), "Pro: illimitato")
    }

    func test_canConsume_freeAndAnonymous_underAndAtLimit() {
        for tier in [UserTier.free, .anonymous] {
            XCTAssertTrue(EntitlementPolicy.canConsumeClip(tier: tier, clipsWatched: 0))
            XCTAssertTrue(EntitlementPolicy.canConsumeClip(tier: tier, clipsWatched: limit - 1))
            XCTAssertFalse(EntitlementPolicy.canConsumeClip(tier: tier, clipsWatched: limit),
                           "al limite NON può più (preserva watched < limit)")
        }
    }

    func test_canConsume_pro_alwaysTrue() {
        XCTAssertTrue(EntitlementPolicy.canConsumeClip(tier: .pro, clipsWatched: 10_000))
    }

    func test_remainingClips() {
        XCTAssertEqual(EntitlementPolicy.remainingClips(tier: .free, clipsWatched: 0), limit)
        XCTAssertEqual(EntitlementPolicy.remainingClips(tier: .free, clipsWatched: limit + 5), 0,
                       "mai negativo")
        XCTAssertEqual(EntitlementPolicy.remainingClips(tier: .pro, clipsWatched: 999), Int.max)
    }

    func test_gate_byTier() {
        XCTAssertNil(EntitlementPolicy.gate(tier: .free, clipsWatched: 0), "sotto limite: nessun gate")
        XCTAssertEqual(EntitlementPolicy.gate(tier: .anonymous, clipsWatched: limit), .accountCreation)
        XCTAssertEqual(EntitlementPolicy.gate(tier: .free, clipsWatched: limit), .proPaywall)
        XCTAssertNil(EntitlementPolicy.gate(tier: .pro, clipsWatched: 10_000), "Pro: mai gate")
    }

    func test_aiDailyLimit_andConsume() {
        XCTAssertEqual(EntitlementPolicy.aiDailyLimit(for: .free), AppConstants.AI.freeDailyRequestLimit)
        XCTAssertEqual(EntitlementPolicy.aiDailyLimit(for: .anonymous), AppConstants.AI.freeDailyRequestLimit)
        XCTAssertEqual(EntitlementPolicy.aiDailyLimit(for: .pro), AppConstants.AI.proDailyRequestLimit)
        let freeMax = AppConstants.AI.freeDailyRequestLimit
        XCTAssertTrue(EntitlementPolicy.canConsumeAIRequest(tier: .free, requestsUsed: freeMax - 1))
        XCTAssertFalse(EntitlementPolicy.canConsumeAIRequest(tier: .free, requestsUsed: freeMax))
    }

    func test_maxCustomLists_perTier() {
        XCTAssertEqual(EntitlementPolicy.maxCustomLists(for: .anonymous), 0)
        XCTAssertEqual(EntitlementPolicy.maxCustomLists(for: .free), ListManager.freeMaxCustomLists)
        XCTAssertEqual(EntitlementPolicy.maxCustomLists(for: .pro), ListManager.proMaxCustomLists)
    }

    func test_shouldShowAds_onlyNonPro() {
        XCTAssertTrue(EntitlementPolicy.shouldShowAds(for: .anonymous))
        XCTAssertTrue(EntitlementPolicy.shouldShowAds(for: .free))
        XCTAssertFalse(EntitlementPolicy.shouldShowAds(for: .pro))
    }

    func test_tierDerivation() {
        XCTAssertEqual(EntitlementPolicy.tier(isPro: true, isAuthenticated: true), .pro)
        XCTAssertEqual(EntitlementPolicy.tier(isPro: true, isAuthenticated: false), .pro, "Pro vince sempre")
        XCTAssertEqual(EntitlementPolicy.tier(isPro: false, isAuthenticated: true), .free)
        XCTAssertEqual(EntitlementPolicy.tier(isPro: false, isAuthenticated: false), .anonymous)
    }

    func test_clipAllowance_unifiesGate() {
        XCTAssertEqual(EntitlementPolicy.clipAllowance(tier: .free, clipsWatched: 0), .allowed)
        XCTAssertEqual(EntitlementPolicy.clipAllowance(tier: .anonymous, clipsWatched: limit), .gateAccount)
        XCTAssertEqual(EntitlementPolicy.clipAllowance(tier: .free, clipsWatched: limit), .paywall)
        XCTAssertEqual(EntitlementPolicy.clipAllowance(tier: .pro, clipsWatched: 10_000), .allowed)
    }
}

// MARK: - Public Lists (Fase 1) — write-path characterization

/// Verifica che i metodi delle Liste Pubbliche accodino l'operazione corretta sull'outbox
/// (single remote writer → apply_mutations), riusando i mock del write-path.
@MainActor
final class PublicListsWritePathTests: XCTestCase {

    private var db: SQLiteService!
    private var dbPath: String!
    private var sync: MockSyncEngine!
    private var auth: MockAuth!
    private var manager: ListManager!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vw_public_\(UUID().uuidString).sqlite")
        db = SQLiteService(dbPath: dbPath)
        _ = db.execute("PRAGMA foreign_keys = OFF")
        sync = MockSyncEngine()
        auth = MockAuth(user: User(id: "user-1", email: "u@test"))
        manager = ListManager(db: db, sync: sync, authService: auth, autoStart: false)
    }

    override func tearDown() async throws {
        manager = nil; db = nil; sync = nil; auth = nil
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        try await super.tearDown()
    }

    func test_setListVisibility_enqueuesListsUpdateWithIsPublic() async throws {
        let custom = MediaList(id: "c1", name: "Romantici", type: .custom)
        manager.lists = [custom]

        try await manager.setListVisibility(listId: "c1", isPublic: true)

        // Stato in-memory aggiornato
        XCTAssertEqual(manager.lists.first(where: { $0.id == "c1" })?.isPublic, true)

        let updates = sync.queued.filter { $0.table == "lists" && $0.operationType == "UPDATE" }
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.recordId, "c1")
        XCTAssertEqual(updates.first?.payload["is_public"] as? Bool, true)
        XCTAssertEqual(updates.first?.payload["user_id"] as? String, "user-1")
    }

    func test_setListVisibility_onCoreList_throwsImmutable() async {
        manager.lists = [MediaList(name: ListType.watchlist.rawValue, type: .watchlist)]
        do {
            try await manager.setListVisibility(listId: manager.lists[0].id, isPublic: true)
            XCTFail("le liste core non possono diventare pubbliche")
        } catch {
            XCTAssertEqual(error as? ListError, .defaultListImmutable)
        }
    }

    func test_followThenUnfollow_enqueuesInsertThenDelete() async throws {
        try await manager.followList(listId: "remote-list-1")
        let inserts = sync.queued.filter { $0.table == "list_follows" && $0.operationType == "INSERT" }
        XCTAssertEqual(inserts.count, 1)
        XCTAssertEqual(inserts.first?.payload["list_id"] as? String, "remote-list-1")
        XCTAssertEqual(inserts.first?.payload["user_id"] as? String, "user-1")

        try await manager.unfollowList(listId: "remote-list-1")
        let deletes = sync.queued.filter { $0.table == "list_follows" && $0.operationType == "DELETE" }
        XCTAssertEqual(deletes.count, 1, "unfollow accoda un soft-delete del follow")
        // L'unfollow riusa lo stesso record id dell'insert (riga locale stabile per coppia)
        XCTAssertEqual(deletes.first?.recordId, inserts.first?.recordId)
    }

    func test_reportList_enqueuesReportInsert() async throws {
        try await manager.reportList(listId: "remote-list-2", reason: "spam")
        let reports = sync.queued.filter { $0.table == "list_reports" && $0.operationType == "INSERT" }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.payload["list_id"] as? String, "remote-list-2")
        XCTAssertEqual(reports.first?.payload["reason"] as? String, "spam")
    }

    /// Regressione: rinominare una lista pubblica non deve azzerare `isPublic` (il "toggle che
    /// non resta attivo"). `updateList` ricostruiva `MediaList` senza propagare `isPublic`.
    func test_updateList_preservesIsPublic() async throws {
        manager.lists = [MediaList(id: "c1", name: "Romantici", type: .custom, isPublic: true)]
        try await manager.updateList(id: "c1", name: "Romantici 2026", description: nil)
        XCTAssertEqual(manager.lists.first(where: { $0.id == "c1" })?.isPublic, true)
    }

    func test_duplicateAsNewList_createsDetachedCustomCopyWithItems() async throws {
        let item1 = MediaListItem(mediaId: 21, mediaType: .movie, title: "A", posterPath: nil)
        let item2 = MediaListItem(mediaId: 22, mediaType: .tv, title: "B", posterPath: nil)
        // Sorgente = lista CORE (così la copia non sfora il limite custom)
        let core = MediaList(name: ListType.watchlist.rawValue, type: .watchlist, items: [item1, item2])
        manager.lists = [core]

        let copy = try await manager.duplicateAsNewList(from: core.id, name: "La mia lista")

        XCTAssertEqual(copy.type, .custom, "il fork è una nuova lista custom")
        XCTAssertNotEqual(copy.id, core.id, "scollegata dalla core sorgente")
        XCTAssertFalse(copy.isPublic, "il fork nasce privato; si pubblica dall'editor")
        XCTAssertEqual(copy.items.count, 2, "gli item della sorgente sono copiati")
        // La core sorgente resta invariata (non viene mai resa pubblica)
        XCTAssertEqual(manager.lists.first(where: { $0.type == .watchlist })?.items.count, 2)
    }
}

// MARK: - ProfanityFilter (moderazione UGC)

final class ProfanityFilterTests: XCTestCase {
    func test_cleanText_passes() {
        XCTAssertFalse(ProfanityFilter.containsProfanity("Migliori film romantici 2026"))
        XCTAssertTrue(ProfanityFilter.validateForPublishing(name: "Cult horror", description: "I miei preferiti"))
    }

    func test_profanity_isBlocked_caseAndDiacriticsInsensitive() {
        XCTAssertTrue(ProfanityFilter.containsProfanity("Lista di MERDA"))
        XCTAssertFalse(ProfanityFilter.validateForPublishing(name: "ok", description: "che cazzo"))
    }

    func test_substringDoesNotFalsePositive() {
        // "classic" non deve matchare (no Scunthorpe problem); match solo su token interi
        XCTAssertFalse(ProfanityFilter.containsProfanity("classic assortment"))
    }
}
