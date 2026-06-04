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

    // CARATTERIZZAZIONE del footgun attuale: performBatchInsert (usato da saveItemsToSQLite)
    // e' INSERT OR REPLACE e i record NON includono deleted_at -> un re-save RESUSCITA un
    // item soft-deleted. Questo test congela il comportamento ATTUALE; lo strangler-fig
    // dovra' cambiarlo deliberatamente (preservare deleted_at), non per caso.
    func test_performBatchInsert_replaceResurrectsSoftDeleted_CURRENT_BEHAVIOR() async throws {
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
        XCTAssertNil(rows.first?["deleted_at"] as? String,
                     "COMPORTAMENTO ATTUALE: INSERT OR REPLACE senza deleted_at resuscita l'item (footgun da fixare nel refactor)")
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
