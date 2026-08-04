import XCTest
@testable import VibeWatchApp

/// "Crea lista pubblica da questa" produceva uno snapshot morto: la copia che gli amici seguono
/// restava ferma al giorno in cui era stata creata, e nessuno se ne accorgeva perché il proprietario
/// vede la sorgente, non la copia.
///
/// Qui si verifica il filo: la copia porta il legame verso la sorgente, e un'aggiunta o una
/// rimozione sulla sorgente arriva anche nella copia — su SQLite **e** sull'outbox, perché una
/// propagazione che non parte è identica a nessuna propagazione.
@MainActor
final class ListLinkPropagationTests: XCTestCase {

    private var db: SQLiteService!
    private var dbPath: String!
    private var sync: MockSyncEngine!
    private var manager: ListManager!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vw_link_\(UUID().uuidString).sqlite")
        db = SQLiteService(dbPath: dbPath)
        _ = db.execute("PRAGMA foreign_keys = OFF")
        sync = MockSyncEngine()
        manager = ListManager(
            db: db, sync: sync, authService: MockAuth(user: Self.user), autoStart: false
        )
        manager.lists = [
            MediaList(name: ListType.watchlist.rawValue, type: .watchlist),
            MediaList(name: ListType.seen.rawValue, type: .seen)
        ]
    }

    override func tearDown() async throws {
        manager = nil; db = nil; sync = nil
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        try await super.tearDown()
    }

    private static let user = User(
        id: "user-1", email: "a@test", displayName: "A", avatarURL: nil,
        createdAt: Date(), updatedAt: Date()
    )

    private static func movie(id: Int) -> Movie {
        Movie(
            id: id, title: "Movie \(id)", overview: "", posterPath: nil, backdropPath: nil,
            releaseDate: "2026-01-01", voteAverage: 7, voteCount: 1, genreIds: nil, genres: nil,
            adult: false, originalLanguage: "en", popularity: 1, runtime: 100, status: nil,
            tagline: nil, productionCountries: nil, imdbId: nil
        )
    }

    private var watchlistId: String { manager.lists.first { $0.type == .watchlist }!.id }

    private func copiaDellaWatchlist() async throws -> MediaList {
        try await manager.duplicateAsNewList(from: watchlistId, name: "Pubblica")
    }

    // MARK: - Il legame

    func testLaCopiaSaDaQualeListaCoreVieneECheNonEUnId() async throws {
        let copia = try await copiaDellaWatchlist()

        XCTAssertEqual(copia.sourceListType, .watchlist,
                       "una core si segue per tipo: il suo id cambia da un'installazione all'altra")
        XCTAssertNil(copia.sourceListId)
    }

    func testIlLegameFinisceSullOutbox() async throws {
        let copia = try await copiaDellaWatchlist()

        let update = sync.queued.last { $0.table == "lists" && $0.recordId == copia.id }
        XCTAssertEqual(update?.payload["source_list_type"] as? String, "watchlist",
                       "senza il push, il legame vivrebbe solo su questo dispositivo")
    }

    func testLaCopiaDiUnaListaCustomPuntaAllId() async throws {
        let sorgente = try await manager.createList(name: "Sorgente")
        let copia = try await manager.duplicateAsNewList(from: sorgente.id, name: "Copia")

        XCTAssertEqual(copia.sourceListId, sorgente.id)
        XCTAssertNil(copia.sourceListType)
    }

    // MARK: - La propagazione

    func testUnAggiuntaAllaSorgenteArrivaNellaCopia() async throws {
        let copia = try await copiaDellaWatchlist()

        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 42), mediaType: .movie)

        let aggiornata = manager.lists.first { $0.id == copia.id }
        XCTAssertEqual(aggiornata?.items.map(\.mediaId), [42],
                       "la copia pubblica deve seguire la lista di origine")
    }

    func testLAggiuntaPropagataFinisceSullOutbox() async throws {
        let copia = try await copiaDellaWatchlist()
        let prima = sync.queued.filter { $0.table == "list_items" }.count

        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 43), mediaType: .movie)

        let inserimenti = sync.queued.filter {
            $0.table == "list_items" && $0.operationType == "INSERT"
                && $0.payload["list_id"] as? String == copia.id
        }
        XCTAssertEqual(inserimenti.count, 1, "anche la riga della copia va spinta al server")
        XCTAssertGreaterThan(sync.queued.filter { $0.table == "list_items" }.count, prima)
    }

    func testUnaRimozioneDallaSorgenteArrivaNellaCopia() async throws {
        let copia = try await copiaDellaWatchlist()
        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 44), mediaType: .movie)

        let item = manager.lists.first { $0.id == watchlistId }!.items.first { $0.mediaId == 44 }!
        try await manager.removeFromList(listId: watchlistId, itemId: item.id)

        let aggiornata = manager.lists.first { $0.id == copia.id }
        XCTAssertTrue(aggiornata?.items.isEmpty == true,
                      "togliere dalla sorgente deve togliere anche dalla copia")
    }

    func testUnaListaSenzaCopieNonPropagaNiente() async throws {
        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 45), mediaType: .movie)

        let inserimenti = sync.queued.filter {
            $0.table == "list_items" && $0.operationType == "INSERT"
        }
        XCTAssertEqual(inserimenti.count, 1, "una sola riga: non c'è nessuna copia da aggiornare")
    }

    /// Le copie di *un'altra* lista non devono muoversi: il legame è per tipo, non "tutte le custom".
    func testLaPropagazioneNonTraboccaSulleAltreCopie() async throws {
        let copiaWatchlist = try await copiaDellaWatchlist()
        let seenId = manager.lists.first { $0.type == .seen }!.id
        let copiaSeen = try await manager.duplicateAsNewList(from: seenId, name: "Viste pubbliche")

        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 46), mediaType: .movie)

        XCTAssertEqual(manager.lists.first { $0.id == copiaWatchlist.id }?.items.count, 1)
        XCTAssertEqual(manager.lists.first { $0.id == copiaSeen.id }?.items.count, 0,
                       "la copia della lista 'viste' non c'entra con un'aggiunta alla watchlist")
    }

    /// Un titolo già presente nella copia non deve far fallire l'aggiunta sulla sorgente.
    func testUnItemGiaPresenteNellaCopiaNonRompeLAggiunta() async throws {
        let copia = try await copiaDellaWatchlist()
        try await manager.addToList(listId: copia.id, movie: Self.movie(id: 47), mediaType: .movie)

        try await manager.addToList(listId: watchlistId, movie: Self.movie(id: 47), mediaType: .movie)

        XCTAssertEqual(manager.lists.first { $0.id == copia.id }?.items.count, 1,
                       "l'item resta uno solo, e nessun errore risale al chiamante")
    }
}
