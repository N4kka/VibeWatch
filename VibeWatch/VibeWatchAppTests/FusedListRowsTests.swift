import XCTest
@testable import VibeWatchApp

/// La regola che decide se una serie è "vista" o "da guardare" nelle liste — e, di riflesso, se
/// il chip "Visto" del dettaglio risulta acceso.
///
/// Il difetto che questi test bloccano: `bucket == "up_to_date"` da solo significa "in pari per
/// ora", non "finita". Una serie in corso, con la prossima uscita già annunciata, finiva fra le
/// **viste** e ci restava — anche dopo che l'episodio nuovo era uscito, perché la lista non
/// guardava più quella riga. Con `next_season` nella condizione, "vista" torna a voler dire
/// "tutti gli episodi usciti visti e nessuno in arrivo".
@MainActor
final class FusedListRowsTests: XCTestCase {

    private var service: SQLiteService!
    private var dbPath: String!
    private let userId = "11111111-1111-1111-1111-111111111111"

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "vibewatch_fused_\(UUID().uuidString).sqlite"
        service = SQLiteService(dbPath: dbPath)
    }

    override func tearDown() async throws {
        service = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    private func repository() -> LocalTrackingRepository {
        LocalTrackingRepository(
            sqlite: service,
            currentUserId: { [userId] in userId },
            language: { "en" }
        )
    }

    private func insertShow(id: Int, name: String, bucket: String, nextSeason: Int?) async throws {
        var row: [String: Any] = [
            "user_id": userId,
            "tmdb_show_id": id,
            "bucket": bucket,
            "show_name": name,
            "user_status": "active",
            "updated_at": "2026-08-01T10:00:00Z"
        ]
        if let nextSeason { row["next_season"] = nextSeason }
        try await service.upsert(table: "tv_tracking", rows: [row])
    }

    func testUnaSerieInPariSenzaProssimoEpisodioEVista() async throws {
        try await insertShow(id: 100, name: "Finita", bucket: "up_to_date", nextSeason: nil)

        let rows = try await repository().fusedListRows(userId: userId)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.isSeen, true,
                       "tutti gli episodi usciti visti e niente in arrivo: è vista")
    }

    func testUnaSerieInPariConUnEpisodioInArrivoNonEVista() async throws {
        try await insertShow(id: 101, name: "In corso", bucket: "up_to_date", nextSeason: 3)

        let rows = try await repository().fusedListRows(userId: userId)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.isSeen, false,
                       "c'è già un episodio futuro annunciato: resta in watchlist")
    }

    func testGliAltriBucketRestanoInWatchlist() async throws {
        try await insertShow(id: 102, name: "Da iniziare", bucket: "not_started", nextSeason: nil)
        try await insertShow(id: 103, name: "Continua", bucket: "up_next", nextSeason: 1)

        let rows = try await repository().fusedListRows(userId: userId)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { !$0.isSeen })
    }

    /// La lista mescola i due casi: è la situazione reale di chi segue più serie.
    func testLaListaSeparaVisteEDaGuardare() async throws {
        try await insertShow(id: 200, name: "Finita", bucket: "up_to_date", nextSeason: nil)
        try await insertShow(id: 201, name: "Rinnovata", bucket: "up_to_date", nextSeason: 2)

        let rows = try await repository().fusedListRows(userId: userId)
        XCTAssertEqual(rows.first { $0.showId == 200 }?.isSeen, true)
        XCTAssertEqual(rows.first { $0.showId == 201 }?.isSeen, false)
    }

    /// Il difetto vero dietro "segno vista una serie e non si sposta mai".
    ///
    /// Il server fa la sua parte: finiti gli episodi, la riga di `v_tv_tracking` torna con
    /// `bucket = up_to_date` e `next_season` NULL. Era lo specchio a non saperla ricevere —
    /// `upsert` scartava i NULL insieme alle colonne assenti, quindi il vecchio prossimo episodio
    /// restava scritto e la serie non superava mai la condizione di "vista".
    func testIlProssimoEpisodioSvuotatoDalServerSvuotaAncheLoSpecchio() async throws {
        try await insertShow(id: 400, name: "Quasi finita", bucket: "up_next", nextSeason: 4)

        // La riga che arriva dal pull dopo l'ultimo episodio visto: gli stessi campi, con il
        // prossimo episodio esplicitamente vuoto.
        try await service.upsert(table: "tv_tracking", rows: [[
            "user_id": userId,
            "tmdb_show_id": 400,
            "bucket": "up_to_date",
            "show_name": "Quasi finita",
            "user_status": "active",
            "next_season": NSNull(),
            "next_episode": NSNull(),
            "backlog_since": NSNull(),
        ]])

        let rows = try await repository().fusedListRows(userId: userId)
        XCTAssertEqual(rows.first?.isSeen, true,
                       "con il prossimo episodio svuotato la serie deve risultare vista")
    }

    /// Le righe di un altro utente non entrano mai nella lista.
    func testLaListaEDelSoloUtenteCorrente() async throws {
        try await insertShow(id: 300, name: "Mia", bucket: "up_to_date", nextSeason: nil)
        try await service.upsert(table: "tv_tracking", rows: [[
            "user_id": "22222222-2222-2222-2222-222222222222",
            "tmdb_show_id": 301,
            "bucket": "up_to_date",
            "show_name": "Di un altro",
            "user_status": "active"
        ]])

        let rows = try await repository().fusedListRows(userId: userId)
        XCTAssertEqual(rows.map(\.showId), [300])
    }
}
