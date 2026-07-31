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
}
