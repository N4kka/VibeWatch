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

    /// Le tre tabelle che §4 elenca ma che nascono coi blocchi 8 e 9 devono restare fuori: una
    /// tabella inesistente nella pull-list è un PGRST205 a ogni sync.
    func testLeTabelleNonAncoraEsistentiRestanoFuori() {
        XCTAssertFalse(SQLiteTable.isValid("user_ratings"))
        XCTAssertFalse(SQLiteTable.isValid("user_favorites"))
        XCTAssertFalse(SQLiteTable.isValid("user_follows"))
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
        let actions = TrackingActions(syncEngine: sync, currentUserId: { "u-1" })

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
        let actions = TrackingActions(syncEngine: sync, currentUserId: { "u-1" })

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

    // MARK: - La sonda di §13.6

    /// Il difetto che rendeva la misura inutile, e che nessuno vedeva perche' un numero c'era.
    ///
    /// La sequenza reale era: `begin()`, `isLoading = true`, SwiftUI ridisegna, la `List` compare
    /// **vuota** — i dati sono ancora dentro l'`await` — e il capolinea scattava li'. Si misurava
    /// il tempo di disegnare una lista vuota. Il `61,9 ms` gia' registrato era stato attribuito
    /// all'account senza storico, ma sarebbe stato altrettanto falso con dati veri.
    func testUnaMisuraChiusaPrimaDeiDatiSiScarta() {
        TrackingPerformanceProbe.begin()

        XCTAssertNil(TrackingPerformanceProbe.firstFrameRendered(),
                     "senza dati non c'e' niente da misurare: meglio nessun numero che uno falso")
    }

    func testUnaMisuraCompletaTornaIlTempo() {
        TrackingPerformanceProbe.begin()
        TrackingPerformanceProbe.dataReady(rows: 24)

        let ms = TrackingPerformanceProbe.firstFrameRendered()

        XCTAssertNotNil(ms)
        XCTAssertGreaterThanOrEqual(ms ?? -1, 0)
    }

    /// Chiudere senza aver mai aperto non produce un numero: sarebbe il tempo dall'avvio dell'app.
    func testChiudereSenzaAvereApertoNonMisuraNiente() {
        _ = TrackingPerformanceProbe.firstFrameRendered()   // svuota un eventuale residuo
        XCTAssertNil(TrackingPerformanceProbe.firstFrameRendered())
    }

    /// Una misura chiusa non si puo' chiudere due volte: il secondo `onAppear` di una `List` che
    /// si ricompone darebbe un tempo piu' lungo per lo stesso evento.
    func testLaMisuraSiChiudeUnaVoltaSola() {
        TrackingPerformanceProbe.begin()
        TrackingPerformanceProbe.dataReady(rows: 1)

        XCTAssertNotNil(TrackingPerformanceProbe.firstFrameRendered())
        XCTAssertNil(TrackingPerformanceProbe.firstFrameRendered())
    }

    func testIlBudgetEQuelloDiSpec() {
        XCTAssertEqual(TrackingPerformanceProbe.budgetMs, 300, "§13.6")
    }
}
