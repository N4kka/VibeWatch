import XCTest
@testable import VibeWatchApp

/// SPEC v3 §3.6 (blocco 9) — le azioni di scrittura di voti e favorites.
///
/// La regola sotto test è quella di tutta la famiglia (`TrackingActions`, `SocialActions`):
/// l'identità la riempie l'azione e solo lei; la forma fuori regola è un **errore vero prima di
/// accodare** — non un rifiuto muto in `sync_rejected_mutations` — e dopo ogni scrittura si
/// rilegge dal server, perché lo specchio locale è ottimistico.
@MainActor
final class FavoritesRatingsActionsTests: XCTestCase {

    private var engine: MockSyncEngine!

    override func setUp() {
        super.setUp()
        engine = MockSyncEngine()
    }

    private func ratings(userId: String? = "u1") -> RatingActions {
        RatingActions(syncEngine: engine, sqlite: .shared, currentUserId: { userId })
    }

    private func favorites(userId: String? = "u1") -> FavoritesActions {
        FavoritesActions(syncEngine: engine, sqlite: .shared, currentUserId: { userId })
    }

    // MARK: - Voti: la forma si rifiuta prima di accodare

    func testUnVotoFuoriScalaNonParte() async {
        for fuori in [0, 11, -3] {
            do {
                try await ratings().rate(mediaType: "movie", tmdbId: 603, rating: fuori)
                XCTFail("\(fuori) doveva essere rifiutato")
            } catch RatingActions.ActionError.invalidRating {
                // atteso
            } catch {
                XCTFail("errore sbagliato: \(error)")
            }
        }
        XCTAssertTrue(engine.queued.isEmpty, "niente in coda: sarebbe morto sul CHECK del server")
        XCTAssertEqual(engine.profileContentPulls, 0)
    }

    func testLaFormaSbagliataNonParte() async {
        // Un episodio senza numeri, e un film con una stagione: la stessa regola del CHECK
        // `user_ratings_shape`, respinta qui dove l'errore si vede.
        await XCTAssertThrowsInvalidShape {
            try await self.ratings().rate(mediaType: "episode", tmdbId: 1399, rating: 8)
        }
        await XCTAssertThrowsInvalidShape {
            try await self.ratings().rate(mediaType: "movie", tmdbId: 603,
                                          seasonNumber: 1, episodeNumber: 1, rating: 8)
        }
        await XCTAssertThrowsInvalidShape {
            try await self.ratings().rate(mediaType: "quiz", tmdbId: 1, rating: 5)
        }
        XCTAssertTrue(engine.queued.isEmpty)
    }

    func testSenzaLoginNonParte() async {
        do {
            try await ratings(userId: nil).rate(mediaType: "movie", tmdbId: 603, rating: 7)
            XCTFail("senza login doveva fallire")
        } catch RatingActions.ActionError.notAuthenticated {
        } catch { XCTFail("errore sbagliato: \(error)") }
        XCTAssertTrue(engine.queued.isEmpty)
    }

    // MARK: - Voti: il percorso buono

    func testIlVotoRiempieLIdentitaEParlaLaLinguaDelServer() async throws {
        try await ratings().rate(mediaType: "movie", tmdbId: 603, rating: 7)

        XCTAssertEqual(engine.queued.count, 1)
        let op = try XCTUnwrap(engine.queued.first)
        XCTAssertEqual(op.table, "user_ratings")
        XCTAssertEqual(op.operationType, "UPSERT")
        XCTAssertEqual(op.payload["user_id"] as? String, "u1",
                       "l'identità la riempie l'azione: senza, user_id_mismatch muto")
        XCTAssertEqual(op.payload["rating"] as? Int, 7)
        XCTAssertNil(op.payload["season_number"],
                     "il record per il server ha NULL, non il sentinello -1 dello specchio")
        XCTAssertNil(op.payload["episode_number"])
        XCTAssertEqual(engine.profileContentPulls, 1, "dopo la scrittura si rilegge")
    }

    func testTogliereUnVotoViaggiaComeDeleteConLaChiave() async throws {
        try await ratings().removeRating(mediaType: "episode", tmdbId: 1399,
                                         seasonNumber: 1, episodeNumber: 1)

        let op = try XCTUnwrap(engine.queued.first)
        XCTAssertEqual(op.operationType, "DELETE")
        // La tabella non ha id sintetico: la chiave viaggia nel record, che è ciò che il ramo
        // DELETE di apply_mutations legge per scrivere la lapide.
        XCTAssertEqual(op.payload["media_type"] as? String, "episode")
        XCTAssertEqual(op.payload["tmdb_id"] as? Int, 1399)
        XCTAssertEqual(op.payload["season_number"] as? Int, 1)
        XCTAssertEqual(op.payload["episode_number"] as? Int, 1)
        XCTAssertEqual(engine.profileContentPulls, 1)
    }

    // MARK: - Favorites

    func testUnoSlotFuoriDaiQuattroNonParte() async {
        for fuori in [0, 5] {
            do {
                try await favorites().setFavorite(mediaType: "movie", slot: fuori, tmdbId: 603)
                XCTFail("lo slot \(fuori) doveva essere rifiutato")
            } catch FavoritesActions.ActionError.invalidSlot {
            } catch { XCTFail("errore sbagliato: \(error)") }
        }
        XCTAssertTrue(engine.queued.isEmpty)
    }

    func testUnFavoriteEUnFilmOUnaSerie() async {
        do {
            try await favorites().setFavorite(mediaType: "episode", slot: 1, tmdbId: 1)
            XCTFail("'episode' doveva essere rifiutato")
        } catch FavoritesActions.ActionError.invalidMediaType {
        } catch { XCTFail("errore sbagliato: \(error)") }
        XCTAssertTrue(engine.queued.isEmpty)
    }

    func testRiempireUnoSlotScriveERilegge() async throws {
        try await favorites().setFavorite(mediaType: "tv", slot: 2, tmdbId: 1399)

        let op = try XCTUnwrap(engine.queued.first)
        XCTAssertEqual(op.table, "user_favorites")
        XCTAssertEqual(op.operationType, "UPSERT")
        XCTAssertEqual(op.payload["user_id"] as? String, "u1")
        XCTAssertEqual(op.payload["slot"] as? Int, 2)
        XCTAssertEqual(op.payload["tmdb_id"] as? Int, 1399)
        XCTAssertEqual(engine.profileContentPulls, 1, "dopo la scrittura si rilegge")
    }

    func testSvuotareUnoSlotEUnaLapideNonUnaDelete() async throws {
        try await favorites().clearFavorite(mediaType: "movie", slot: 1)

        let op = try XCTUnwrap(engine.queued.first)
        XCTAssertEqual(op.operationType, "DELETE",
                       "il ramo DELETE del server scrive deleted_at: la DELETE fisica non ha grant")
        XCTAssertEqual(op.payload["media_type"] as? String, "movie")
        XCTAssertEqual(op.payload["slot"] as? Int, 1)
        XCTAssertEqual(engine.profileContentPulls, 1)
    }

    // MARK: - Helper

    private func XCTAssertThrowsInvalidShape(_ body: @escaping () async throws -> Void,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) async {
        do {
            try await body()
            XCTFail("doveva rifiutare la forma", file: file, line: line)
        } catch RatingActions.ActionError.invalidShape {
        } catch {
            XCTFail("errore sbagliato: \(error)", file: file, line: line)
        }
    }
}
