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

    // MARK: - Review (social feed M1)

    private func reviews(userId: String? = "u1") -> ReviewActions {
        ReviewActions(syncEngine: engine, sqlite: .shared, currentUserId: { userId })
    }

    /// Il DB del simulatore persiste fra i run: senza pulizia il "riuso dell'id" troverebbe
    /// la riga del run precedente.
    private func purgeReviews(tmdbId: Int) async {
        try? await SQLiteService.shared.executeWrite(
            "DELETE FROM user_reviews WHERE tmdb_id = ?", parameters: [tmdbId])
    }

    func testUnaReviewVuotaOTroppoLungaNonParte() async {
        for fuori in ["", "   \n ", String(repeating: "a", count: 281)] {
            do {
                try await reviews().setReview(mediaType: "movie", tmdbId: 603, content: fuori)
                XCTFail("il contenuto doveva essere rifiutato")
            } catch ReviewActions.ActionError.invalidContent {
            } catch { XCTFail("errore sbagliato: \(error)") }
        }
        XCTAssertTrue(engine.queued.isEmpty, "niente in coda: sarebbe morto sul CHECK del server")
        XCTAssertEqual(engine.profileContentPulls, 0)
    }

    func testUnaReviewEUnFilmOUnaSerie() async {
        do {
            try await reviews().setReview(mediaType: "episode", tmdbId: 1399, content: "ok")
            XCTFail("'episode' doveva essere rifiutato")
        } catch ReviewActions.ActionError.invalidMediaType {
        } catch { XCTFail("errore sbagliato: \(error)") }
        XCTAssertTrue(engine.queued.isEmpty)
    }

    func testLaReviewRiempieLIdentitaTrimmaERiusaLId() async throws {
        await purgeReviews(tmdbId: 777001)

        try await reviews().setReview(mediaType: "movie", tmdbId: 777001,
                                      content: "  Capolavoro assoluto.  ",
                                      containsSpoilers: true)
        let op = try XCTUnwrap(engine.queued.first)
        XCTAssertEqual(op.table, "user_reviews")
        XCTAssertEqual(op.operationType, "UPSERT")
        XCTAssertEqual(op.payload["user_id"] as? String, "u1",
                       "l'identità la riempie l'azione: senza, user_id_mismatch muto")
        XCTAssertEqual(op.payload["content"] as? String, "Capolavoro assoluto.",
                       "il contenuto viaggia trimmato, come lo conta il CHECK")
        XCTAssertEqual(op.payload["contains_spoilers"] as? Bool, true)
        let id = try XCTUnwrap(op.payload["id"] as? String)
        XCTAssertEqual(op.recordId, id)

        // Il re-write è la STESSA review: report e activities referenziano l'id, che non cambia.
        try await reviews().setReview(mediaType: "movie", tmdbId: 777001, content: "Rivisto: mah.")
        XCTAssertEqual(engine.queued.last?.payload["id"] as? String, id,
                       "riscrivere riusa l'id della riga viva, non ne genera un secondo")
        XCTAssertEqual(engine.profileContentPulls, 2, "dopo ogni scrittura si rilegge")

        let local = await reviews().review(for: "movie", tmdbId: 777001)
        XCTAssertEqual(local?.content, "Rivisto: mah.")
    }

    func testTogliereLaReviewViaggiaComeDeleteConLId() async throws {
        await purgeReviews(tmdbId: 777002)
        try await reviews().setReview(mediaType: "tv", tmdbId: 777002, content: "Da vedere")
        let id = try XCTUnwrap(engine.queued.first?.payload["id"] as? String)

        try await reviews().removeReview(mediaType: "tv", tmdbId: 777002)
        let op = try XCTUnwrap(engine.queued.last)
        XCTAssertEqual(op.operationType, "DELETE",
                       "il ramo DELETE del server scrive deleted_at: la DELETE fisica non ha grant")
        XCTAssertEqual(op.payload["id"] as? String, id,
                       "il ramo DELETE cerca la riga per id: il record lo deve portare")

        let local = await reviews().review(for: "tv", tmdbId: 777002)
        XCTAssertNil(local, "la lapide locale è immediata: la UI non mostra una review tolta")
    }

    func testTogliereUnaReviewCheNonCEsisteNonInventaMutazioni() async throws {
        await purgeReviews(tmdbId: 777003)
        try await reviews().removeReview(mediaType: "movie", tmdbId: 777003)
        XCTAssertTrue(engine.queued.isEmpty)
        XCTAssertEqual(engine.profileContentPulls, 0)
    }

    // MARK: - Parsing (§9.3)

    func testIlProfiloPortaIFavorites() {
        let detail = PublicProfileDetail(json: [
            "found": true, "id": "u1", "username": "anna_r",
            "favorites": [
                "movie": [["slot": 1, "tmdb_id": 603], ["slot": 3, "tmdb_id": 604]],
                "tv": [["slot": 2, "tmdb_id": 1399]],
            ],
        ])
        XCTAssertEqual(detail?.favoriteMovies, [FavoriteSlot(slot: 1, tmdbId: 603),
                                                FavoriteSlot(slot: 3, tmdbId: 604)])
        XCTAssertEqual(detail?.favoriteShows, [FavoriteSlot(slot: 2, tmdbId: 1399)])
    }

    func testUnProfiloSenzaFavoritesNonERotto() {
        let detail = PublicProfileDetail(json: ["found": true, "id": "u1", "username": "anna_r"])
        XCTAssertEqual(detail?.favoriteMovies, [])
        XCTAssertEqual(detail?.favoriteShows, [])
    }

    func testLeStatsSiLeggono() {
        let stats = UserStats(json: ["watch_time_seconds": 14100, "episodes_watched": 3,
                                     "shows_watched": 1, "movies_watched": 1, "ratings_given": 4])
        XCTAssertEqual(stats?.watchTimeSeconds, 14100)
        XCTAssertEqual(stats?.episodesWatched, 3)
    }

    /// Una risposta senza il tempo non diventa un pannello di zeri: e' un errore del chiamante.
    func testStatsIllegibiliSonoNilNonZeri() {
        XCTAssertNil(UserStats(json: [:]))
        XCTAssertNil(UserStats(json: ["episodes_watched": 3]))
    }

    // MARK: - Stats avanzate (§9.3/§10)

    /// Le ripartizioni avanzate si decodificano e mantengono l'ordinamento del server.
    func testLeRipartizioniAvanzateSiLeggonoNellOrdineDelServer() {
        let stats = UserStats(json: [
            "watch_time_seconds": 3600,
            "per_genere": [["genre_id": 10765, "shows": 4, "seconds": 7200],
                           ["genre_id": 18, "shows": 9, "seconds": 3600]],
            "per_decade": [["decade": 2010, "shows": 12, "seconds": 9000]],
            "voti_distribuzione": [["rating": 7, "count": 3]],
            "shows_senza_genere": 1,
        ])
        XCTAssertEqual(stats?.perGenere, [
            UserStats.GenreSlice(genreId: 10765, shows: 4, seconds: 7200),
            UserStats.GenreSlice(genreId: 18, shows: 9, seconds: 3600),
        ], "l'ordinamento e' del server e non si riordina qui")
        XCTAssertEqual(stats?.perDecade, [UserStats.DecadeSlice(decade: 2010, shows: 12, seconds: 9000)])
        XCTAssertEqual(stats?.votiDistribuzione, [UserStats.RatingBucket(rating: 7, count: 3)])
        XCTAssertEqual(stats?.showsSenzaGenere, 1)
        XCTAssertEqual(stats?.hasAdvancedBreakdowns, true)
    }

    /// Un utente senza niente da ripartire non ha la sezione: vuoto non e' un errore.
    func testSenzaRipartizioniLaSezioneNonEsiste() {
        let stats = UserStats(json: ["watch_time_seconds": 0])
        XCTAssertEqual(stats?.hasAdvancedBreakdowns, false)
    }

    /// I generi TV di TMDB (10759-10768) hanno un nome; un id sconosciuto si dichiara come
    /// "#id" invece di sparire o di rompere la lista.
    func testIGeneriTVHannoUnNomeEQuelliIgnotiSiDichiarano() {
        XCTAssertEqual(AdvancedStatsPresentation.genreLabel(10765), "Sci-Fi & Fantasy")
        XCTAssertEqual(AdvancedStatsPresentation.genreLabel(10759), "Action & Adventure")
        XCTAssertEqual(AdvancedStatsPresentation.genreLabel(18), "Drama")
        XCTAssertEqual(AdvancedStatsPresentation.genreLabel(424242), "#424242")
    }

    /// Le etichette derivate: decade neutra, stelle a mezzi passi, ore da secondi VERI —
    /// sotto l'ora si dichiara "<1 h", mai uno "0 h" su un dato reale.
    func testLeEtichetteDelleRipartizioni() {
        XCTAssertEqual(AdvancedStatsPresentation.decadeLabel(1990), "1990s")
        XCTAssertEqual(AdvancedStatsPresentation.starsLabel(7), "3.5")
        XCTAssertEqual(AdvancedStatsPresentation.starsLabel(10), "5")
        XCTAssertEqual(AdvancedStatsPresentation.starsLabel(1), "0.5")
        XCTAssertEqual(AdvancedStatsPresentation.hoursLabel(0), "0 h")
        XCTAssertEqual(AdvancedStatsPresentation.hoursLabel(1800), "<1 h")
        XCTAssertEqual(AdvancedStatsPresentation.hoursLabel(7200), "2 h")
    }

    /// La griglia dei totali nella dashboard: un fetch fallito e' `.failed` dichiarato, mai una
    /// griglia di zeri con la faccia di un dato.
    func testLeStatsFalliteSiDichiarano() async {
        struct Rotto: Error {}
        let rotto = ProfileStatsViewModel(fetch: { throw Rotto() })
        await rotto.load()
        XCTAssertEqual(rotto.phase, .failed)

        let ok = ProfileStatsViewModel(fetch: {
            UserStats(watchTimeSeconds: 0, episodesWatched: 0, showsWatched: 0,
                      moviesWatched: 0, ratingsGiven: 0)
        })
        await ok.load()
        XCTAssertEqual(ok.phase, .loaded(UserStats(watchTimeSeconds: 0, episodesWatched: 0,
                                                   showsWatched: 0, moviesWatched: 0,
                                                   ratingsGiven: 0)),
                       "gli zeri veri sono un dato, non un errore")
    }

    // MARK: - Le stelle (§3.6)

    func testLaStellaScriveELoStatoResta() async {
        let vm = StarRatingViewModel(
            mediaType: "movie", tmdbId: 603,
            actions: RatingActions(syncEngine: engine, sqlite: .shared, currentUserId: { "u1" }),
            sqlite: .shared, currentUserId: { "u1" })
        await vm.setRating(7)

        XCTAssertEqual(vm.rating, 7)
        XCTAssertFalse(vm.saveFailed)
        XCTAssertEqual(engine.queued.first?.payload["rating"] as? Int, 7)
    }

    /// Toccare lo stesso valore toglie il voto, come Letterboxd: parte una DELETE, non un upsert.
    func testToccareLoStessoValoreToglieIlVoto() async {
        let vm = StarRatingViewModel(
            mediaType: "movie", tmdbId: 603,
            actions: RatingActions(syncEngine: engine, sqlite: .shared, currentUserId: { "u1" }),
            sqlite: .shared, currentUserId: { "u1" })
        await vm.setRating(7)
        await vm.setRating(7)

        XCTAssertEqual(vm.rating, 0)
        XCTAssertEqual(engine.queued.last?.operationType, "DELETE")
    }

    /// La regola di tutta la sessione: un voto che il server non ha mai saputo non resta sullo
    /// schermo a mentire.
    func testLaStellaCheFallisceTornaIndietro() async {
        // currentUserId nil dentro le azioni: la scrittura fallisce con notAuthenticated.
        let vm = StarRatingViewModel(
            mediaType: "movie", tmdbId: 603,
            actions: RatingActions(syncEngine: engine, sqlite: .shared, currentUserId: { nil }),
            sqlite: .shared, currentUserId: { "u1" })
        await vm.setRating(8)

        XCTAssertEqual(vm.rating, 0, "lo stato torna quello vero")
        XCTAssertTrue(vm.saveFailed, "e il fallimento si dichiara")
        XCTAssertTrue(engine.queued.isEmpty)
    }

    // MARK: - Il diario (§9.3)

    private func diaryEntry(id: String, mediaType: String = "tv") -> DiaryEntry {
        DiaryEntry(id: id, mediaType: mediaType, tmdbId: 900,
                   title: mediaType == "tv" ? "Show" : nil,
                   episodeLabel: mediaType == "tv" ? "S1E1" : nil,
                   posterPath: nil, watchedAt: Date(timeIntervalSince1970: 0), isInferred: false)
    }

    /// Vuoto, righe e lettura fallita sono tre stati, mai schiacciati.
    func testIlDiarioVuotoNonEUnErrore() async {
        let vuoto = DiaryViewModel(fetchPage: { _, _ in [] }, resolveMovieTitle: { _ in nil },
                                   resolveShowTitle: { _ in nil })
        await vuoto.load()
        XCTAssertEqual(vuoto.phase, .empty)

        struct Rotto: Error {}
        let rotto = DiaryViewModel(fetchPage: { _, _ in throw Rotto() }, resolveMovieTitle: { _ in nil },
                                   resolveShowTitle: { _ in nil })
        await rotto.load()
        XCTAssertEqual(rotto.phase, .failed, "una lettura fallita non e' 'non hai visto niente'")
    }

    func testIlDiarioPaginaSenzaPerdereLeRigheGiaMostrate() async {
        let prima = (0..<DiaryViewModel.pageSize).map { self.diaryEntry(id: "e\($0)") }
        let seconda = [diaryEntry(id: "extra1"), diaryEntry(id: "extra2")]
        let vm = DiaryViewModel(
            fetchPage: { _, offset in offset == 0 ? prima : seconda },
            resolveMovieTitle: { _ in nil }, resolveShowTitle: { _ in nil })
        await vm.load()
        await vm.loadMoreIfNeeded(current: prima.last!)

        guard case .loaded(let entries, let hasMore) = vm.phase else {
            return XCTFail("doveva essere loaded, era \(vm.phase)")
        }
        XCTAssertEqual(entries.count, DiaryViewModel.pageSize + 2)
        XCTAssertFalse(hasMore, "una pagina corta chiude la camminata")
    }

    func testIlTitoloDeiFilmSiRisolveDalClient() async {
        let vm = DiaryViewModel(
            fetchPage: { _, _ in [self.diaryEntry(id: "m1", mediaType: "movie")] },
            resolveMovieTitle: { id in id == 900 ? "Heat" : nil },
            resolveShowTitle: { _ in nil })
        await vm.load()
        XCTAssertEqual(vm.movieTitles[900], "Heat",
                       "il catalogo film locale non esiste: il nome arriva dal client")
    }

    /// Il nome nello specchio e' quello del catalogo condiviso (§1.5), una lingua sola: il
    /// titolo nella lingua dell'app si risolve dal client, e il nome inglese resta il ripiego
    /// per l'offline — un titolo vero in una lingua sbagliata batte un buco.
    func testIlTitoloDelleSerieSiRisolveNellaLinguaDellApp() async {
        let vm = DiaryViewModel(
            fetchPage: { _, _ in [self.diaryEntry(id: "e1")] },
            resolveMovieTitle: { _ in nil },
            resolveShowTitle: { id in id == 900 ? "La Serie" : nil })
        await vm.load()
        XCTAssertEqual(vm.showTitles[900], "La Serie")
    }

    /// La forma della riga: la data dedotta si dichiara, l'episodio porta la sua etichetta.
    func testUnaRigaDelDiarioSiLeggeDallaCache() {
        let tv = LocalDiaryRepository.entry(from: [
            "id": "e1", "media_type": "tv", "tmdb_show_id": 900,
            "season_number": 1, "episode_number": 3,
            "watched_at": "2026-07-31T10:00:00Z", "watched_at_precision": "inferred",
            "show_name": "Stats Show", "show_poster_path": "/p.jpg",
        ])
        XCTAssertEqual(tv?.title, "Stats Show")
        XCTAssertEqual(tv?.episodeLabel, "S1E3")
        XCTAssertEqual(tv?.isInferred, true, "una data dedotta non si spaccia per esatta")

        let film = LocalDiaryRepository.entry(from: [
            "id": "e2", "media_type": "movie", "tmdb_movie_id": 603,
            "watched_at": "2026-07-31T10:00:00Z",
        ])
        XCTAssertEqual(film?.tmdbId, 603)
        XCTAssertNil(film?.title, "il nome del film non c'e' in cache: lo risolve il chiamante")

        XCTAssertNil(LocalDiaryRepository.entry(from: ["id": "e3", "media_type": "tv",
                                                       "watched_at": "non-una-data"]),
                     "una riga illeggibile si scarta, non si inventa")
    }

    // MARK: - Il pulsante dei favorites (§3.6)

    func testLoSlotSiSceglieEScrive() async {
        let vm = FavoriteButtonViewModel(
            mediaType: "movie", tmdbId: 603,
            actions: FavoritesActions(syncEngine: engine, sqlite: .shared, currentUserId: { "u1" }),
            sqlite: .shared, currentUserId: { "u1" })
        await vm.setSlot(2)

        XCTAssertEqual(vm.currentSlot, 2)
        XCTAssertTrue(vm.occupiedSlots.contains(2))
        XCTAssertEqual(engine.queued.first?.payload["slot"] as? Int, 2)
    }

    func testUnFavoritoCheFallisceTornaIndietro() async {
        let vm = FavoriteButtonViewModel(
            mediaType: "movie", tmdbId: 603,
            actions: FavoritesActions(syncEngine: engine, sqlite: .shared, currentUserId: { nil }),
            sqlite: .shared, currentUserId: { "u1" })
        await vm.setSlot(3)

        XCTAssertNil(vm.currentSlot, "lo stato torna quello vero")
        XCTAssertFalse(vm.occupiedSlots.contains(3))
        XCTAssertTrue(vm.saveFailed, "e il fallimento si dichiara")
        XCTAssertTrue(engine.queued.isEmpty)
    }

    func testRimuovereLiberaLoSlotEViaggiaComeDelete() async {
        let vm = FavoriteButtonViewModel(
            mediaType: "movie", tmdbId: 603,
            actions: FavoritesActions(syncEngine: engine, sqlite: .shared, currentUserId: { "u1" }),
            sqlite: .shared, currentUserId: { "u1" })
        await vm.setSlot(1)
        await vm.remove()

        XCTAssertNil(vm.currentSlot)
        XCTAssertFalse(vm.occupiedSlots.contains(1))
        XCTAssertEqual(engine.queued.last?.operationType, "DELETE")
    }

    // MARK: - La cache dei titoli localizzati (§1.5 vs §13.6)

    /// Il DB del simulatore PERSISTE fra i run: senza pulizia, un test che scrive in
    /// localized_titles passa al primo giro e fallisce al secondo, quando la riga c'e' gia'.
    private func purgeLocalizedTitles(id: Int) async {
        try? await SQLiteService.shared.executeWrite(
            "DELETE FROM localized_titles WHERE tmdb_id = ?", parameters: [id])
    }

    /// Il giro completo: buco -> fetch -> scritto -> il secondo giro legge la cache e non
    /// chiama piu' la rete. E' la proprieta' che tiene il Tracking dentro §13.6.
    func testUnTitoloSiRisolveUnaVoltaSola() async {
        await purgeLocalizedTitles(id: 424242)
        var fetches = 0
        let store = LocalizedTitleStore(
            sqlite: .shared,
            language: { "it" },
            fetchRemote: { _, id in fetches += 1; return id == 424242 ? "Il Trono" : nil })

        let wrote = await store.refreshMissing(mediaType: "tv", ids: [424242])
        XCTAssertTrue(wrote, "il primo giro scrive")
        XCTAssertEqual(fetches, 1)

        let again = await store.refreshMissing(mediaType: "tv", ids: [424242])
        XCTAssertFalse(again, "il secondo giro non ha buchi: niente rete, niente rilancio")
        XCTAssertEqual(fetches, 1, "la cache risponde lei")

        let cached = await store.cachedTitles(mediaType: "tv", ids: [424242])
        XCTAssertEqual(cached[424242], "Il Trono")
    }

    /// Un fetch fallito non scrive e risponde false: chi ascolta non ricarica e non si
    /// rincorre. Il titolo del catalogo resta a schermo, che e' il ripiego onesto.
    func testUnFetchFallitoNonRilancia() async {
        let store = LocalizedTitleStore(
            sqlite: .shared, language: { "it" },
            fetchRemote: { _, _ in nil })
        let wrote = await store.refreshMissing(mediaType: "tv", ids: [434343])
        XCTAssertFalse(wrote)
        let cached = await store.cachedTitles(mediaType: "tv", ids: [434343])
        XCTAssertNil(cached[434343])
    }

    /// La lingua fa parte della chiave: cambiare lingua non trova i titoli vecchi e rifetcha.
    func testLaLinguaFaParteDellaChiave() async {
        await purgeLocalizedTitles(id: 454545)
        let it = LocalizedTitleStore(sqlite: .shared, language: { "it" },
                                     fetchRemote: { _, _ in "Il Trono" })
        await it.refreshMissing(mediaType: "tv", ids: [454545])

        let de = LocalizedTitleStore(sqlite: .shared, language: { "de" },
                                     fetchRemote: { _, _ in "Der Thron" })
        let cachedDe = await de.cachedTitles(mediaType: "tv", ids: [454545])
        XCTAssertNil(cachedDe[454545], "il titolo italiano non risponde per il tedesco")
    }

    /// Gli episodi si riempiono per STAGIONE: una chiamata porta tutta la stagione, e il
    /// secondo giro non ha buchi ne' rete. Trovato sul dispositivo il 2026-08-01: i titoli
    /// delle serie erano tradotti, i nomi degli episodi no.
    func testINomiDegliEpisodiSiRiempionoPerStagione() async {
        await purgeLocalizedTitles(id: 515151)
        var seasonFetches = 0
        let store = LocalizedTitleStore(
            sqlite: .shared, language: { "it" },
            fetchRemote: { _, _ in nil },
            fetchSeason: { _, season in
                seasonFetches += 1
                return season == 4 ? [1: "Episodio Uno", 2: "Episodio Due"] : nil
            })
        let refs: Set<LocalizedTitleStore.EpisodeRef> = [.init(season: 4, episode: 1),
                                                         .init(season: 4, episode: 2)]

        let wrote = await store.refreshMissingEpisodeNames(showId: 515151, refs: refs)
        XCTAssertTrue(wrote)
        XCTAssertEqual(seasonFetches, 1, "una chiamata per stagione, non per episodio")

        let cached = await store.cachedEpisodeNames(showId: 515151, refs: Array(refs))
        XCTAssertEqual(cached[.init(season: 4, episode: 1)], "Episodio Uno")

        let again = await store.refreshMissingEpisodeNames(showId: 515151, refs: refs)
        XCTAssertFalse(again, "il secondo giro non ha buchi: niente rete, niente rilancio")
        XCTAssertEqual(seasonFetches, 1)
    }

    /// Una stagione che TMDB restituisce SENZA l'episodio cercato (numerazioni divergenti, §6)
    /// non deve far ricaricare nessuno: wrote = false, il nome del catalogo resta a schermo.
    func testUnaStagioneSenzaLEpisodioCercatoNonRilancia() async {
        await purgeLocalizedTitles(id: 525252)
        let store = LocalizedTitleStore(
            sqlite: .shared, language: { "it" },
            fetchRemote: { _, _ in nil },
            fetchSeason: { _, _ in [1: "Episodio Uno"] })
        let wrote = await store.refreshMissingEpisodeNames(
            showId: 525252, refs: [.init(season: 1, episode: 99)])
        XCTAssertFalse(wrote)
    }

    // MARK: - La pillola del provider (streaming > noleggio > acquisto > avvisami)

    private func provider(_ name: String, logo: String = "/logo.png") -> Provider {
        Provider(providerId: abs(name.hashValue % 100_000), providerName: name,
                 logoPath: logo, displayPriority: 1)
    }

    func testLoStreamingVinceSuNoleggioEAcquisto() {
        let result = ProviderSelection.selectTopProviderWithTier(from: CountryProviders(
            flatrate: [provider("Netflix")], rent: [provider("Apple TV")],
            buy: [provider("Amazon")], link: "https://justwatch.example"))
        XCTAssertEqual(result.top?.providerName, "Netflix")
        XCTAssertEqual(result.tier, .flatrate)
    }

    func testSenzaStreamingIlNoleggioPrecedeLAcquisto() {
        let result = ProviderSelection.selectTopProviderWithTier(from: CountryProviders(
            flatrate: nil, rent: [provider("Apple TV")], buy: [provider("Amazon")],
            link: "https://justwatch.example"))
        XCTAssertEqual(result.top?.providerName, "Apple TV")
        XCTAssertEqual(result.tier, .rent)

        let soloAcquisto = ProviderSelection.selectTopProviderWithTier(from: CountryProviders(
            flatrate: nil, rent: nil, buy: [provider("Amazon")],
            link: "https://justwatch.example"))
        XCTAssertEqual(soloAcquisto.tier, .buy)
    }

    /// Un provider senza logo usabile non vince lo scaffale: si scende a quello dopo,
    /// identico al comportamento storico di ListsView.
    func testUnProviderSenzaLogoNonVinceLoScaffale() {
        let result = ProviderSelection.selectTopProviderWithTier(from: CountryProviders(
            flatrate: [provider("Rotto", logo: "/logo-white.svg")],
            rent: [provider("Apple TV")], buy: nil, link: "https://justwatch.example"))
        XCTAssertEqual(result.top?.providerName, "Apple TV")
        XCTAssertEqual(result.tier, .rent)
    }

    func testNessunoScaffaleEAvvisami() {
        let result = ProviderSelection.selectTopProviderWithTier(from: CountryProviders(
            flatrate: nil, rent: nil, buy: nil, link: nil))
        XCTAssertNil(result.top)
        XCTAssertNil(result.tier, "nessuno scaffale: la pillola diventa Avvisami")
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
