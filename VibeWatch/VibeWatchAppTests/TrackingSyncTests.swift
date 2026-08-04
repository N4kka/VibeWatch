import XCTest
@testable import VibeWatchApp

/// Unit tests for the tracking tables joining the sync (SPEC v3 §4, blocco 5).
final class TrackingSyncTests: XCTestCase {

    // MARK: - Whitelist

    /// Senza whitelist ogni scrittura muore con `invalidTableName` — che è il modo in cui
    /// `watch_providers` è rimasta senza dati per mesi (vedi il commento in `SQLiteTable`).
    func testLeTabelleDiTrackingSonoNellaWhitelist() {
        XCTAssertTrue(SQLiteTable.isValid("watch_events"))
        XCTAssertTrue(SQLiteTable.isValid("tv_show_state"))
    }

    /// Fino al blocco 9 questo test verificava il contrario — che `user_ratings` e
    /// `user_favorites` restassero FUORI dalla whitelist, perché una tabella inesistente nella
    /// pull-list è un PGRST205 a ogni sync. Dal 2026-07-31 esistono in produzione (RLS, rami in
    /// apply_mutations), quindi ora si fissa il positivo: dentro, e `lastWriteWins` esplicita
    /// (§4) — mai nel `default`, che è una decisione non presa.
    func testFavoritesEVotiSonoInWhitelistEInLastWriteWins() {
        XCTAssertTrue(SQLiteTable.isValid("user_ratings"))
        XCTAssertTrue(SQLiteTable.isValid("user_favorites"))
        XCTAssertEqual(TableConflictMapping.strategy(for: "user_ratings"), .lastWriteWins)
        XCTAssertEqual(TableConflictMapping.strategy(for: "user_favorites"), .lastWriteWins)
    }

    /// §3.6: la coppia (follower, followee) si sincronizza come `union` — un follow non si perde.
    func testIFollowSonoInWhitelistEInUnion() {
        XCTAssertTrue(SQLiteTable.isValid("user_follows"))
        XCTAssertEqual(TableConflictMapping.strategy(for: "user_follows"), .union)
    }

    // MARK: - Strategie di conflitto (§4)

    func testGliEventiSiUnisconoInveceDiSovrascriversi() {
        XCTAssertEqual(TableConflictMapping.strategy(for: "watch_events"), .union,
                       "append-only: non si perde mai una visione")
    }

    func testLoStatoDellaSerieLoDecideIlServer() {
        XCTAssertEqual(TableConflictMapping.strategy(for: "tv_show_state"), .serverWins,
                       "è derivato dagli eventi e ricalcolato lato server (§1.1)")
    }

    /// Le strategie già assegnate non devono cambiare per l'aggiunta dei due rami nuovi.
    func testLeStrategieEsistentiRestanoInvariate() {
        XCTAssertEqual(TableConflictMapping.strategy(for: "lists"), .union)
        XCTAssertEqual(TableConflictMapping.strategy(for: "user_gamification"), .maxWins)
        XCTAssertEqual(TableConflictMapping.strategy(for: "movie_reactions"), .lastWriteWins)
        XCTAssertEqual(TableConflictMapping.strategy(for: "clips"), .serverWins)
    }

    // MARK: - Finestra del pull (§5)

    func testGliEventiSiRitiranoSoloPerDodiciMesi() {
        let finestra = SyncEngine.pullWindow(for: "watch_events")

        XCTAssertEqual(finestra?.column, "watched_at")
        XCTAssertEqual(finestra?.months, 12, "coincide col confine free/PRO del diario (§10)")
    }

    /// Lo stato della serie è una riga per serie: filtrarlo nel tempo lo renderebbe incompleto,
    /// e la schermata Tracking mostrerebbe meno serie di quelle che l'utente segue.
    func testLoStatoDellaSerieNonHaFinestra() {
        XCTAssertNil(SyncEngine.pullWindow(for: "tv_show_state"))
    }

    func testLeAltreTabelleNonHannoFinestra() {
        XCTAssertNil(SyncEngine.pullWindow(for: "lists"))
        XCTAssertNil(SyncEngine.pullWindow(for: "profiles"))
        XCTAssertNil(SyncEngine.pullWindow(for: "movie_reactions"))
    }

    // MARK: - Le azioni della schermata (§9.2)

    /// Il difetto trovato usando l'app: premere "visto" scriveva l'evento in produzione e **non
    /// cambiava niente sullo schermo**. Il progresso lo ricalcola il server (§1.1) e la schermata
    /// legge lo specchio locale `tv_tracking`, che solo un pull aggiorna — quindi la card restava
    /// identica e sembrava che il tap non fosse arrivato.
    @MainActor
    func testSegnareVistoRitiraLoStatoRicalcolatoDalServer() async throws {
        let sync = MockSyncEngine()
        let actions = TrackingActions(
            syncEngine: sync, currentUserId: { "u-1" }, mirror: FakeWatchEventMirror())

        try await actions.markNextWatched(rigaConProssimoEpisodio())

        XCTAssertEqual(sync.queued.first?.table, "watch_events")
        XCTAssertEqual(sync.trackingPulls, 1,
                       "senza il pull la schermata resta ferma e il tap sembra perso")
    }

    /// `user_id` nel record non è un dettaglio: `apply_mutations` lo confronta con `auth.uid()` e,
    /// se manca, scrive `user_id_mismatch` in `sync_rejected_mutations` **e prosegue**.
    @MainActor
    func testLEventoPortaSempreUserIdEPrecisioneEsatta() async throws {
        let sync = MockSyncEngine()
        let actions = TrackingActions(
            syncEngine: sync, currentUserId: { "u-1" }, mirror: FakeWatchEventMirror())

        try await actions.markNextWatched(rigaConProssimoEpisodio())

        let record = try XCTUnwrap(sync.queued.first?.payload)
        XCTAssertEqual(record["user_id"] as? String, "u-1")
        // Qui la data di visione è davvero adesso: è l'utente che sta premendo il pulsante.
        XCTAssertEqual(record["watched_at_precision"] as? String, "exact")
        XCTAssertNil(record["dedup_key"], "il rewatch manuale è intenzionalmente ripetibile (§3.2)")
    }

    /// "Più avanti" cambia il bucket, e il bucket lo calcola `tv_tracking_bucket` sul server.
    @MainActor
    func testRimandareRitiraAncheLuiLoStato() async throws {
        let sync = MockSyncEngine()
        let actions = TrackingActions(syncEngine: sync, currentUserId: { "u-1" })

        try await actions.snooze(rigaConProssimoEpisodio())

        XCTAssertEqual(sync.queued.first?.table, "tv_show_state")
        XCTAssertEqual(sync.queued.first?.payload["user_status"] as? String, "for_later")
        XCTAssertEqual(sync.trackingPulls, 1)
    }

    /// Una serie in pari non ha un prossimo episodio: si rifiuta invece di inventarne uno.
    @MainActor
    func testSenzaProssimoEpisodioNonSiScriveNiente() async {
        let sync = MockSyncEngine()
        let actions = TrackingActions(syncEngine: sync, currentUserId: { "u-1" })

        do {
            try await actions.markNextWatched(rigaSenzaProssimoEpisodio())
            XCTFail("doveva rifiutare")
        } catch {}

        XCTAssertTrue(sync.queued.isEmpty)
        XCTAssertEqual(sync.trackingPulls, 0)
    }

    /// Il pull mirato tocca le tre tabelle del tracking e nient'altro: un pull completo per un
    /// tocco sarebbe 19 tabelle.
    func testIlPullMiratoToccaSoloLeTabelleDelTracking() {
        XCTAssertEqual(SyncEngine.trackingTables,
                       ["tv_show_state", "v_tv_tracking", "v_tv_timeline"])
    }

    /// Le due viste sono specchi: nessuno in locale le scrive, quindi la riga che arriva deve
    /// sostituire quella che c'è. Erano nel `default`, `lastWriteWins`, che le confronta per
    /// `updated_at` — e `v_tv_timeline` un `updated_at` non ce l'ha.
    func testLeVisteDelTrackingSonoSpecchiDelServer() {
        XCTAssertEqual(TableConflictMapping.strategy(for: "v_tv_tracking"), .serverWins)
        XCTAssertEqual(TableConflictMapping.strategy(for: "v_tv_timeline"), .serverWins)
    }

    // MARK: - Le azioni episodio-livello (lista episodi di SeasonDetailView)

    /// Il difetto del redesign: il tap sulla lista episodi scriveva solo EpisodeSeenManager
    /// (UserDefaults) e le card di Scopri/Tracking — che leggono lo specchio calcolato dal
    /// server — non si muovevano. Ora passa dallo stesso canale della card: evento + pull.
    @MainActor
    func testSegnareUnEpisodioDallaListaScriveLEventoERitiraLoStato() async throws {
        let sync = MockSyncEngine()
        let mirror = FakeWatchEventMirror()
        let actions = TrackingActions(syncEngine: sync, currentUserId: { "u-1" }, mirror: mirror)

        try await actions.markEpisodesWatched(showId: 1396, episodes: [(2, 1)])

        XCTAssertEqual(sync.queued.count, 1)
        XCTAssertEqual(sync.queued.first?.table, "watch_events")
        XCTAssertEqual(sync.queued.first?.operationType, "INSERT")
        XCTAssertEqual(sync.queued.first?.payload["user_id"] as? String, "u-1")
        XCTAssertEqual(sync.queued.first?.payload["season_number"] as? Int, 2)
        XCTAssertEqual(sync.queued.first?.payload["episode_number"] as? Int, 1)
        XCTAssertEqual(sync.trackingPulls, 1, "senza il pull le card restano ferme")
        XCTAssertEqual(mirror.inserted.count, 1,
                       "il write-through è ciò che permette poi di smarcare prima del pull completo")
    }

    /// "Hai visto anche i precedenti?" marca N episodi in un colpo: un evento ciascuno, un pull.
    @MainActor
    func testSegnareIPrecedentiAccodaUnEventoPerEpisodioEUnSoloPull() async throws {
        let sync = MockSyncEngine()
        let actions = TrackingActions(
            syncEngine: sync, currentUserId: { "u-1" }, mirror: FakeWatchEventMirror())

        try await actions.markEpisodesWatched(showId: 1396, episodes: [(2, 1), (2, 2), (2, 3)])

        XCTAssertEqual(sync.queued.count, 3)
        XCTAssertEqual(sync.queued.map { $0.payload["episode_number"] as? Int }, [1, 2, 3])
        XCTAssertEqual(sync.trackingPulls, 1, "un pull per il lotto, non uno per episodio")
    }

    /// Lo smarcamento mette la lapide su OGNI evento noto di quell'episodio (rewatch compresi):
    /// DELETE remota per id + tombstone locale, così la lista non lo rivede al prossimo pull.
    @MainActor
    func testSmarcareUnEpisodioCancellaTuttiISuoiEventi() async throws {
        let sync = MockSyncEngine()
        let mirror = FakeWatchEventMirror()
        mirror.idsByEpisode["2-1"] = ["ev-a", "ev-b"]
        let actions = TrackingActions(syncEngine: sync, currentUserId: { "u-1" }, mirror: mirror)

        try await actions.unmarkEpisodesWatched(
            showId: 1396, episodes: [(2, 1)], allEpisodeNumbersInSeason: [1, 2, 3])

        XCTAssertEqual(sync.queued.map(\.operationType), ["DELETE", "DELETE"])
        XCTAssertEqual(sync.queued.map(\.recordId), ["ev-a", "ev-b"])
        XCTAssertEqual(sync.queued.first?.payload["user_id"] as? String, "u-1",
                       "senza user_id apply_mutations scarta in silenzio")
        XCTAssertEqual(mirror.tombstoned, ["ev-a", "ev-b"])
        XCTAssertEqual(sync.trackingPulls, 1)
    }

    /// Un episodio visto solo in locale (nessun evento nello specchio) si smarca senza accodare
    /// DELETE inventate: il pull finale riallinea comunque lo stato.
    @MainActor
    func testSmarcareSenzaEventiNotiNonAccodaNiente() async throws {
        let sync = MockSyncEngine()
        let actions = TrackingActions(
            syncEngine: sync, currentUserId: { "u-1" }, mirror: FakeWatchEventMirror())

        try await actions.unmarkEpisodesWatched(
            showId: 1396, episodes: [(2, 1)], allEpisodeNumbersInSeason: [1, 2])

        XCTAssertTrue(sync.queued.isEmpty)
        XCTAssertEqual(sync.trackingPulls, 1)
    }

    @MainActor
    func testLeAzioniEpisodioRichiedonoLAutenticazione() async {
        let sync = MockSyncEngine()
        let actions = TrackingActions(
            syncEngine: sync, currentUserId: { nil }, mirror: FakeWatchEventMirror())

        do {
            try await actions.markEpisodesWatched(showId: 1, episodes: [(1, 1)])
            XCTFail("doveva rifiutare")
        } catch {}
        do {
            try await actions.unmarkEpisodesWatched(
                showId: 1, episodes: [(1, 1)], allEpisodeNumbersInSeason: [1])
            XCTFail("doveva rifiutare")
        } catch {}

        XCTAssertTrue(sync.queued.isEmpty)
        XCTAssertEqual(sync.trackingPulls, 0)
    }

    // MARK: - Riparazione del catalogo mancante

    /// Una serie aggiunta alla watchlist prima che il catalogo esistesse resta senza poster né
    /// prossimo episodio (la card "Da iniziare" col check pieno). La riparazione riscalda il
    /// catalogo e ri-upserta lo user_status corrente: è ciò che fa ripartire il ricalcolo
    /// server, che `catalog-resolve` da solo non tocca.
    @MainActor
    func testRiparareIlCatalogoRiscaldaEPoiFaRicalcolare() async {
        let sync = MockSyncEngine()
        let backend = MockSeenBackend()
        let actions = TrackingActions(
            syncEngine: sync, currentUserId: { "u-1" },
            seenBackend: backend, mirror: FakeWatchEventMirror())

        await actions.repairMissingCatalog(rows: [(101, "active"), (102, "for_later")])

        XCTAssertEqual(backend.warmed, [[101, 102]], "un warm solo, in lotto")
        let stateOps = sync.queued.filter { $0.table == "tv_show_state" }
        XCTAssertEqual(stateOps.count, 2)
        XCTAssertEqual(stateOps.map { $0.payload["user_status"] as? String },
                       ["active", "for_later"],
                       "si ri-scrive lo stato che c'era: la riparazione non cambia la scelta dell'utente")
        XCTAssertEqual(sync.trackingPulls, 1)
    }

    /// Se il warm fallisce (offline), ricalcolare produrrebbe gli stessi zeri: non si accoda
    /// niente e si riproverà alla prossima apertura.
    @MainActor
    func testSenzaCatalogoLaRiparazioneNonAccodaNiente() async {
        let sync = MockSyncEngine()
        let backend = MockSeenBackend()
        backend.warmError = URLError(.notConnectedToInternet)
        let actions = TrackingActions(
            syncEngine: sync, currentUserId: { "u-1" },
            seenBackend: backend, mirror: FakeWatchEventMirror())

        await actions.repairMissingCatalog(rows: [(101, "active")])

        XCTAssertTrue(sync.queued.isEmpty)
        XCTAssertEqual(sync.trackingPulls, 0)
    }

    /// L'origine del difetto: aggiungere alla watchlist senza riscaldare il catalogo faceva
    /// nascere la riga vuota. Ora il warm precede lo stato.
    @MainActor
    func testAggiungereAllaWatchlistRiscaldaPrimaIlCatalogo() async throws {
        let sync = MockSyncEngine()
        let backend = MockSeenBackend()
        let actions = TrackingActions(
            syncEngine: sync, currentUserId: { "u-1" },
            seenBackend: backend, mirror: FakeWatchEventMirror())

        try await actions.addToWatchlist(showId: 1396)

        XCTAssertEqual(backend.warmed, [[1396]])
        XCTAssertEqual(sync.queued.first?.table, "tv_show_state")
        XCTAssertEqual(sync.queued.first?.payload["user_status"] as? String, "active")
    }

    // MARK: - Righe di prova

    private func rigaConProssimoEpisodio() -> TrackingRow {
        TrackingRow(
            showId: 1396, userStatus: "active", bucket: .upNext,
            watchedCount: 10, airedCount: 62, totalCount: 62,
            nextSeason: 2, nextEpisode: 3, nextEpisodeName: "Bit by a Dead Bee",
            nextAirDate: nil, isNextAvailable: true,
            backlogSince: nil, lastWatchedAt: nil,
            showName: "Breaking Bad", posterPath: nil, nextStillPath: nil
        )
    }

    private func rigaSenzaProssimoEpisodio() -> TrackingRow {
        TrackingRow(
            showId: 1396, userStatus: "active", bucket: .upToDate,
            watchedCount: 62, airedCount: 62, totalCount: 62,
            nextSeason: nil, nextEpisode: nil, nextEpisodeName: nil,
            nextAirDate: nil, isNextAvailable: false,
            backlogSince: nil, lastWatchedAt: nil,
            showName: "Breaking Bad", posterPath: nil, nextStillPath: nil
        )
    }

    /// Lo specchio locale come dizionario: niente SQLite nei test delle azioni.
    private final class FakeWatchEventMirror: WatchEventLocalMirror, @unchecked Sendable {
        private(set) var inserted: [[String: Any]] = []
        var idsByEpisode: [String: [String]] = [:]
        private(set) var tombstoned: [String] = []

        func insert(_ record: [String: Any]) async { inserted.append(record) }
        func activeEventIds(userId: String, showId: Int, season: Int, episode: Int) async -> [String] {
            idsByEpisode["\(season)-\(episode)"] ?? []
        }
        func tombstone(ids: [String]) async { tombstoned.append(contentsOf: ids) }
    }

    // MARK: - La sonda di §13.6

    /// La schermata può già avere contenuto quando l'utente apre la tab: il ViewModel si ricarica
    /// anche su `syncEngineCompleted`. In quel caso il capolinea scatta **prima** di `dataReady`,
    /// e il numero giusto è "quasi zero" — non "misura da scartare".
    ///
    /// La versione precedente la scartava e, peggio, **lasciava il cronometro armato**: sul
    /// dispositivo un secondo `onAppear` quaranta secondi dopo l'ha chiuso stampando
    /// `OLTRE IL BUDGET: totale 40500.6 ms`. Un numero assurdo è peggio di nessun numero.
    func testUnaSchermataGiaPopolataProduceUnaMisuraValida() {
        TrackingPerformanceProbe.begin()

        let ms = TrackingPerformanceProbe.firstFrameRendered()

        XCTAssertNotNil(ms, "il contenuto era già a schermo: è la misura buona, non da buttare")
        XCTAssertGreaterThanOrEqual(ms ?? -1, 0)
    }

    /// La cosa che ha prodotto i 40 secondi: scartare senza disarmare.
    func testUnaMisuraScartataDisarmaIlCronometro() {
        let inizio = CFAbsoluteTimeGetCurrent() - 40
        TrackingPerformanceProbe.begin(at: inizio)

        XCTAssertNil(TrackingPerformanceProbe.firstFrameRendered(),
                     "40 s non sono un fotogramma")

        // Il secondo `onAppear`, con un intervallo che da solo sarebbe plausibile. Se il
        // cronometro fosse rimasto armato tornerebbe 50 ms — un numero pulito per un evento che
        // non c'entra niente, cioe' il modo peggiore di sbagliare.
        // Ripetere la stessa chiamata di sopra non proverebbe niente: sarebbe scartata di nuovo
        // dalla soglia, e il test passerebbe anche senza il disarmo (verificato togliendolo).
        XCTAssertNil(TrackingPerformanceProbe.firstFrameRendered(at: inizio + 0.05),
                     "il cronometro non resta armato ad aspettare un secondo onAppear")
    }

    /// La soglia scarta l'assurdo, non il lento: un 900 ms vero va visto, non nascosto.
    func testUnaMisuraLentaMaPlausibileSiRiporta() {
        let inizio = CFAbsoluteTimeGetCurrent()
        TrackingPerformanceProbe.begin(at: inizio)
        TrackingPerformanceProbe.dataReady(rows: 24)

        let ms = TrackingPerformanceProbe.firstFrameRendered(at: inizio + 0.9)

        XCTAssertEqual(ms ?? 0, 900, accuracy: 1, "oltre budget, ma è un numero vero")
    }

    func testUnaMisuraCompletaTornaIlTempo() {
        let inizio = CFAbsoluteTimeGetCurrent()
        TrackingPerformanceProbe.begin(at: inizio)
        TrackingPerformanceProbe.dataReady(rows: 24)

        XCTAssertEqual(TrackingPerformanceProbe.firstFrameRendered(at: inizio + 0.15) ?? 0,
                       150, accuracy: 1)
    }

    /// Chiudere senza aver mai aperto non produce un numero: sarebbe il tempo dall'avvio dell'app.
    func testChiudereSenzaAvereApertoNonMisuraNiente() {
        _ = TrackingPerformanceProbe.firstFrameRendered()   // svuota un eventuale residuo
        XCTAssertNil(TrackingPerformanceProbe.firstFrameRendered())
    }

    /// Una misura chiusa non si può chiudere due volte: il secondo `onAppear` di una `List` che
    /// si ricompone darebbe un tempo più lungo per lo stesso evento.
    func testLaMisuraSiChiudeUnaVoltaSola() {
        TrackingPerformanceProbe.begin()
        TrackingPerformanceProbe.dataReady(rows: 1)

        XCTAssertNotNil(TrackingPerformanceProbe.firstFrameRendered())
        XCTAssertNil(TrackingPerformanceProbe.firstFrameRendered())
    }

    func testIlBudgetEQuelloDiSpec() {
        XCTAssertEqual(TrackingPerformanceProbe.budgetMs, 300, "§13.6")
        XCTAssertGreaterThan(TrackingPerformanceProbe.abandonAfterMs,
                             TrackingPerformanceProbe.budgetMs,
                             "la soglia di abbandono deve stare sopra il budget, o nasconderebbe i fallimenti veri")
    }
}
