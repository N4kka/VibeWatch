import XCTest
@testable import VibeWatchApp

/// SPEC v3 blocco 7 — la migrazione dello storico di chi usava VibeWatch prima del tracking nuovo.
///
/// Il difetto che questa migrazione chiude era **invisibile leggendo il codice**: pull a posto,
/// 19 tabelle su 19, e schermata vuota, perche' per quell'utente il server non aveva niente. I
/// test qui sotto stanno tutti sulla stessa classe di guasto: qualcosa che riesce a meta' e si
/// dichiara riuscito.
@MainActor
final class LegacyTrackingMigrationTests: XCTestCase {

    // MARK: - La parte pura: cosa va migrato

    func testUnaChiaveBenFormataDiventaUnEpisodio() {
        let episodio = LegacyTrackingPlan.parse("1399_2_5")

        XCTAssertEqual(episodio, LegacyTrackingPlan.Episode(showId: 1399, season: 2, episode: 5))
    }

    /// Una chiave rotta non e' un episodio "quasi giusto". Interpretarla a caso produrrebbe un
    /// evento plausibile e falso, che poi entra nel progresso e non lo nota nessuno.
    func testUnaChiaveRottaSiScartaInveceDiIndovinare() {
        XCTAssertNil(LegacyTrackingPlan.parse("1399_2"), "un pezzo in meno")
        XCTAssertNil(LegacyTrackingPlan.parse("1399_2_5_7"), "un pezzo in piu'")
        XCTAssertNil(LegacyTrackingPlan.parse("1399_x_5"), "una stagione che non e' un numero")
        XCTAssertNil(LegacyTrackingPlan.parse(""), "vuota")
        XCTAssertNil(LegacyTrackingPlan.parse("1399__5"), "un campo vuoto in mezzo")
        XCTAssertNil(LegacyTrackingPlan.parse("-3_1_1"), "un id di serie negativo")
        XCTAssertNil(LegacyTrackingPlan.parse("1399_-1_1"), "una stagione negativa")
    }

    /// La stagione 0 e' l'unica sorgente di verita' sulla specialita' (§1.3), quindi va letta,
    /// non filtrata via in ingresso.
    func testLoSpecialeSiLeggeEdEntraNelPiano() {
        XCTAssertEqual(LegacyTrackingPlan.parse("1399_0_1")?.season, 0)
    }

    func testIlPianoEDeterministicoENonHaDuplicati() {
        let primo = LegacyTrackingPlan.build(
            seenKeys: ["1399_1_2", "1399_1_1", "66732_1_1"], seenShowIds: [], seenListShowIds: [])
        let secondo = LegacyTrackingPlan.build(
            seenKeys: ["66732_1_1", "1399_1_1", "1399_1_2"], seenShowIds: [], seenListShowIds: [])

        XCTAssertEqual(primo, secondo, "l'ordine di un Set cambia a ogni esecuzione, il piano no")
        XCTAssertEqual(primo.episodes.count, 3)
    }

    /// Le due sorgenti delle "serie viste per intero" si uniscono. `ListManager` marca gia'
    /// `markShowSeen` quando aggiunge alla lista, ma quel flag vive in UserDefaults: una
    /// installazione nuova che ritira le liste dal server ha la lista e non il flag.
    func testLeSerieVistePerInteroVengonoDaEntrambeLeSorgenti() {
        let piano = LegacyTrackingPlan.build(
            seenKeys: [], seenShowIds: [1399], seenListShowIds: [66732, 1399])

        XCTAssertEqual(piano.wholeShows, [1399, 66732], "unione, non scelta, e senza duplicati")
    }

    /// Gli episodi singoli di una serie vista per intero **restano**: l'espansione conosce solo
    /// cio' che sta nel catalogo, e l'oracolo documenta 41 serie su 430 in cui la numerazione
    /// dell'utente e quella di TMDB non coincidono. La dedup_key fa si' che non costino niente.
    func testGliEpisodiSingoliNonSiPerdonoSeLaSerieEVistaPerIntero() {
        let piano = LegacyTrackingPlan.build(
            seenKeys: ["1399_1_1"], seenShowIds: [1399], seenListShowIds: [])

        XCTAssertEqual(piano.episodes.count, 1)
        XCTAssertEqual(piano.wholeShows, [1399])
    }

    func testLeSerieDaRiscaldareSonoLUnioneSenzaRipetizioni() {
        let piano = LegacyTrackingPlan.build(
            seenKeys: ["1399_1_1", "1399_1_2", "66732_1_1"],
            seenShowIds: [95396], seenListShowIds: [1399])

        XCTAssertEqual(Set(piano.showIds), [1399, 66732, 95396])
        XCTAssertEqual(piano.showIds.count, 3, "nessuna serie chiesta due volte a catalog-resolve")
    }

    // MARK: - Il record che finisce in apply_mutations

    func testIlRecordPortaUserIdPrecisionEDedupKey() {
        let episodio = LegacyTrackingPlan.Episode(showId: 1399, season: 2, episode: 5)
        let record = LegacyTrackingPlan.record(
            for: episodio, userId: "u-1", watchedAt: Date(timeIntervalSince1970: 0))

        // Senza `user_id`, apply_mutations scrive `user_id_mismatch` in sync_rejected_mutations
        // e prosegue: nessun errore al client, l'evento sparisce.
        XCTAssertEqual(record["user_id"] as? String, "u-1")
        // §3.2: la data di visione vera non esiste in UserDefaults. `exact` la inventerebbe.
        XCTAssertEqual(record["watched_at_precision"] as? String, "inferred")
        XCTAssertEqual(record["dedup_key"] as? String, "legacy:1399:2:5")
        XCTAssertEqual(record["source"] as? String, "import_other")
        XCTAssertEqual(record["media_type"] as? String, "tv")
        XCTAssertEqual(record["is_special"] as? Bool, false)
    }

    /// §1.3: la specialita' viene dalla stagione, mai da un flag deciso altrove.
    func testLaSpecialitaVieneDallaStagione() {
        let speciale = LegacyTrackingPlan.record(
            for: .init(showId: 1399, season: 0, episode: 1), userId: "u", watchedAt: Date())

        XCTAssertEqual(speciale["is_special"] as? Bool, true)
    }

    /// La chiave di dedup e' la stessa che usa l'espansione server-side: le due sorgenti devono
    /// convergere sulla stessa riga, non produrne due (criterio 2 di §13).
    func testLaDedupKeyHaLaFormaCheUsaAncheIlServer() {
        XCTAssertEqual(
            LegacyTrackingPlan.dedupKey(.init(showId: 42, season: 0, episode: 7)), "legacy:42:0:7")
    }

    // MARK: - L'esecuzione

    func testUnaMigrazioneGiaFattaNonRifaNiente() async {
        let store = FakeStore(version: LegacyTrackingMigration.currentVersion)
        let backend = FakeBackend()

        let report = await migration(backend, store).runIfNeeded(userId: "u-1")

        XCTAssertNil(report)
        XCTAssertTrue(backend.mutationsInviate.isEmpty)
    }

    /// Senza utente non si segna niente: un record senza `user_id` verrebbe scartato in silenzio,
    /// e segnare "fatta" perderebbe lo storico per sempre.
    func testSenzaUtenteSiRimandaSenzaSegnareFatta() async {
        let store = FakeStore(plan: .init(episodes: [.init(showId: 1, season: 1, episode: 1)],
                                          wholeShows: []))
        let backend = FakeBackend()

        let report = await migration(backend, store).runIfNeeded(userId: nil)

        XCTAssertNil(report)
        XCTAssertEqual(store.storedVersion, 0, "resta da fare")
        XCTAssertTrue(backend.mutationsInviate.isEmpty)
    }

    func testNienteDaMigrareChiudeSubito() async {
        let store = FakeStore(plan: .init(episodes: [], wholeShows: []))

        let report = await migration(FakeBackend(), store).runIfNeeded(userId: "u-1")

        XCTAssertEqual(report?.completed, true)
        XCTAssertEqual(store.storedVersion, LegacyTrackingMigration.currentVersion)
    }

    func testIlPercorsoCompletoScriveRiscaldaEspandeERitira() async {
        let store = FakeStore(
            plan: .init(
                episodes: [.init(showId: 1399, season: 1, episode: 1),
                           .init(showId: 1399, season: 1, episode: 2)],
                wholeShows: [66732]),
            watchedAt: [1399: Date(timeIntervalSince1970: 1_000_000)])
        let backend = FakeBackend(espansione: .init(eventsWritten: 10, showsWithoutCatalog: []))
        var ritirato = false

        let report = await migration(backend, store, pull: { ritirato = true })
            .runIfNeeded(userId: "u-1")

        XCTAssertEqual(backend.showsRiscaldati, [1399, 66732], "il catalogo prima di tutto")
        XCTAssertEqual(backend.mutationsInviate.count, 2)
        XCTAssertEqual(report?.episodesQueued, 2)
        XCTAssertEqual(report?.eventsFromExpansion, 10)
        XCTAssertEqual(report?.wholeShowsExpanded, 1)
        XCTAssertEqual(report?.completed, true)
        XCTAssertEqual(store.storedVersion, LegacyTrackingMigration.currentVersion)
        XCTAssertTrue(ritirato, "senza il pull la schermata resta vuota fino al sync successivo")
    }

    /// La data di aggiunta alla lista e' l'unico timestamp reale che questo storico possiede, ed
    /// e' cio' che fa funzionare `backlog_since` (§3.3): con `now()` su tutto, ogni serie
    /// arretrata finirebbe in cima a "Da guardare" nello stesso istante.
    func testLaDataDiAggiuntaAllaListaDiventaWatchedAt() async {
        let quandoAggiunta = Date(timeIntervalSince1970: 1_600_000_000)
        let store = FakeStore(
            plan: .init(episodes: [.init(showId: 1399, season: 1, episode: 1)], wholeShows: []),
            watchedAt: [1399: quandoAggiunta])
        let backend = FakeBackend()

        _ = await migration(backend, store).runIfNeeded(userId: "u-1")

        let record = backend.mutationsInviate.first?["record"] as? [String: Any]
        XCTAssertEqual(record?["watched_at"] as? String,
                       ISO8601DateFormatter().string(from: quandoAggiunta))
    }

    /// Una scrittura fallita **non** deve segnare la migrazione come fatta: il prossimo avvio
    /// rigioca, e la dedup_key impedisce i duplicati. Segnarla fatta qui perderebbe lo storico.
    func testUnaScritturaFallitaLasciaLaMigrazioneDaRifare() async {
        let store = FakeStore(
            plan: .init(episodes: [.init(showId: 1, season: 1, episode: 1)], wholeShows: []))
        let backend = FakeBackend(erroreInScrittura: true)

        let report = await migration(backend, store).runIfNeeded(userId: "u-1")

        XCTAssertEqual(report?.completed, false)
        XCTAssertEqual(store.storedVersion, 0)
    }

    /// Una serie che il catalogo non conosce ancora non chiude la migrazione: il riscaldamento
    /// puo' essere stato tagliato dal budget o dalla deadline di `catalog-resolve`.
    func testUnaSerieSenzaCatalogoNonChiudeLaMigrazione() async {
        let store = FakeStore(plan: .init(episodes: [], wholeShows: [66732]))
        let backend = FakeBackend(
            espansione: .init(eventsWritten: 0, showsWithoutCatalog: [66732]))

        let report = await migration(backend, store).runIfNeeded(userId: "u-1")

        XCTAssertEqual(report?.showsWithoutCatalog, [66732])
        XCTAssertEqual(report?.completed, false)
        XCTAssertEqual(store.storedVersion, 0, "si riprova al prossimo avvio")
    }

    /// Ma non per sempre. Una serie che TMDB non conosce piu' non si risolvera' mai, e riprovare
    /// a ogni lancio sarebbe un ciclo che nessuno nota.
    func testDopoTroppiTentativiSiChiudeComunque() async {
        let store = FakeStore(
            attempts: LegacyTrackingMigration.maxAttempts,
            plan: .init(episodes: [], wholeShows: [66732]))
        let backend = FakeBackend()

        let report = await migration(backend, store).runIfNeeded(userId: "u-1")

        XCTAssertNil(report)
        XCTAssertEqual(store.storedVersion, LegacyTrackingMigration.currentVersion)
        XCTAssertTrue(backend.showsRiscaldati.isEmpty, "e non si spende altro budget di catalogo")
    }

    /// Un catalogo che non si riscalda peggiora la card, non perde il dato: gli episodi si
    /// scrivono lo stesso, perche' `watch_events.tmdb_show_id` non ha una FK sul catalogo.
    func testIlCatalogoIrraggiungibileNonBloccaLaScritturaDegliEventi() async {
        let store = FakeStore(
            plan: .init(episodes: [.init(showId: 1, season: 1, episode: 1)], wholeShows: []))
        let backend = FakeBackend(erroreNelCatalogo: true)

        let report = await migration(backend, store).runIfNeeded(userId: "u-1")

        XCTAssertEqual(report?.episodesQueued, 1)
        XCTAssertEqual(report?.completed, true)
    }

    // MARK: - Doppi

    private func migration(
        _ backend: FakeBackend,
        _ store: FakeStore,
        pull: @escaping @MainActor () async -> Void = {}
    ) -> LegacyTrackingMigration {
        LegacyTrackingMigration(backend: backend, store: store, pullAfterwards: pull)
    }

    @MainActor
    private final class FakeBackend: LegacyTrackingMigrationBackend {
        var showsRiscaldati: [Int] = []
        var mutationsInviate: [[String: Any]] = []
        var espansioniChieste: [[String: Any]] = []

        private let espansione: LegacyExpansionOutcome
        private let erroreInScrittura: Bool
        private let erroreNelCatalogo: Bool

        struct Fallito: Error {}

        init(
            espansione: LegacyExpansionOutcome = .init(eventsWritten: 0, showsWithoutCatalog: []),
            erroreInScrittura: Bool = false,
            erroreNelCatalogo: Bool = false
        ) {
            self.espansione = espansione
            self.erroreInScrittura = erroreInScrittura
            self.erroreNelCatalogo = erroreNelCatalogo
        }

        func warmCatalog(showIds: [Int]) async throws {
            if erroreNelCatalogo { throw Fallito() }
            showsRiscaldati.append(contentsOf: showIds)
        }

        func writeEvents(_ mutations: [[String: Any]]) async throws {
            if erroreInScrittura { throw Fallito() }
            mutationsInviate.append(contentsOf: mutations)
        }

        func expandSeenShows(_ shows: [[String: Any]]) async throws -> LegacyExpansionOutcome {
            espansioniChieste.append(contentsOf: shows)
            return espansione
        }
    }

    @MainActor
    private final class FakeStore: LegacyTrackingMigrationStore {
        var storedVersion: Int
        var storedAttempts: Int
        private let plan: LegacyTrackingPlan
        private let watchedAt: [Int: Date]

        init(
            version: Int = 0,
            attempts: Int = 0,
            plan: LegacyTrackingPlan = .init(episodes: [], wholeShows: []),
            watchedAt: [Int: Date] = [:]
        ) {
            self.storedVersion = version
            self.storedAttempts = attempts
            self.plan = plan
            self.watchedAt = watchedAt
        }

        func version() async -> Int { storedVersion }
        func setVersion(_ version: Int) { storedVersion = version }
        func attempts() async -> Int { storedAttempts }
        func setAttempts(_ attempts: Int) { storedAttempts = attempts }
        func readPlan() -> LegacyTrackingPlan { plan }
        func watchedAtByShow() async -> [Int: Date] { watchedAt }
    }
}
