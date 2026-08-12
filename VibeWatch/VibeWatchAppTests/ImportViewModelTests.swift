import XCTest
@testable import VibeWatchApp

/// SPEC v3 §7 — il flusso di import visto dal client. Il ViewModel è un oblò sul job (le fasi
/// le muove il server): questi test verificano che ogni esito del server abbia una resa
/// distinta, e che nessun errore si travesta da "vuoto" o da "in corso".
@MainActor
final class ImportViewModelTests: XCTestCase {

    // MARK: - Il doppio

    @MainActor
    private final class Fake: ImportBackend {
        struct Rotto: Error {}

        var currentJob: ImportJobSnapshot?
        var report: ImportReport?
        var uploadFails = false
        var uploadSessionExpired = false
        var jobReadFails = false
        var reportFails = false
        var createOutcome: ImportStartOutcome?
        var retryOutcome = ImportStartOutcome(ok: true)

        private(set) var uploads = 0
        private(set) var creates = 0
        private(set) var retries = 0

        func uploadZip(_ data: Data) async throws -> String {
            uploads += 1
            if uploadSessionExpired { throw SupabaseError.sessionExpired }
            if uploadFails { throw Rotto() }
            return "utente/file.zip"
        }

        func createJob(storagePath: String) async throws -> ImportStartOutcome {
            creates += 1
            if let outcome = createOutcome { return outcome }
            currentJob = ImportJobSnapshot(id: "j1", phase: "uploaded", status: "running",
                                           error: nil)
            return ImportStartOutcome(ok: true, jobId: "j1")
        }

        func retryJob(id: String) async throws -> ImportStartOutcome {
            retries += 1
            if retryOutcome.ok {
                currentJob = ImportJobSnapshot(id: id, phase: currentJob?.phase ?? "uploaded",
                                               status: "running", error: nil)
            }
            return retryOutcome
        }

        func latestJob() async throws -> ImportJobSnapshot? {
            if jobReadFails { throw Rotto() }
            return currentJob
        }

        func job(id: String) async throws -> ImportJobSnapshot? {
            if jobReadFails { throw Rotto() }
            return currentJob
        }

        func report(jobId: String) async throws -> ImportReport {
            if reportFails { throw Rotto() }
            guard let report else { throw Rotto() }
            return report
        }

        var manualResolveFails = false
        private(set) var manualResolves: [(jobId: String, resolutions: [ImportManualResolution])] = []

        func manualResolve(jobId: String, resolutions: [ImportManualResolution]) async throws {
            if manualResolveFails { throw Rotto() }
            manualResolves.append((jobId, resolutions))
            // Il server riapre il job una volta sola: tutte le serie vengono riconfermate nello
            // stesso passaggio tramite gli ID TVDB esatti dei rispettivi episodi.
            currentJob = ImportJobSnapshot(id: jobId, phase: "resolving", status: "running",
                                           error: nil)
        }

        var excludeFails = false
        private(set) var excludes:
            [(jobId: String, seriesIds: [String], movieUuids: [String], titles: [String])] = []

        func excludeUnresolved(jobId: String, seriesIds: [String], movieUuids: [String],
                               seriesTitles: [String]) async throws {
            if excludeFails { throw Rotto() }
            excludes.append((jobId, seriesIds, movieUuids, seriesTitles))
        }
    }

    private static let unReport = ImportReport(
        episodiImportati: 42, serieImportate: 3, dal: "2020-01-01", al: "2024-06-01",
        nonRiconosciutiEpisodi: 5, nonRiconosciutiSerie: 1,
        nonRiconosciutiElenco: [.init(titolo: "Sconosciuta", episodi: 5, motivo: "no match",
                                      tvdbSeriesId: "901")],
        votiStelle: 7, votiReaction: 2, votiImportati: false)

    /// Intervallo lungo apposta: il giro di polling lo guidano i test con `pollOnce`,
    /// non l'orologio.
    private func makeVM(_ fake: Fake) -> ImportViewModel {
        ImportViewModel(backend: fake, pollInterval: .seconds(600),
                        readZip: { _ in Data("zip".utf8) })
    }

    // MARK: - Il giro felice

    func testStartFelice() async {
        let fake = Fake()
        fake.report = Self.unReport
        let vm = makeVM(fake)

        await vm.start(zipData: Data("zip".utf8))
        guard case .running(let jobId, _) = vm.state else {
            return XCTFail("dopo la creazione del job lo stato è running, era \(vm.state)")
        }
        XCTAssertEqual(jobId, "j1")
        XCTAssertEqual(fake.uploads, 1)
        XCTAssertEqual(fake.creates, 1)

        fake.currentJob = ImportJobSnapshot(id: "j1", phase: "parsing", status: "running",
                                            error: nil)
        await vm.pollOnce(jobId: "j1")
        XCTAssertEqual(vm.state, .running(jobId: "j1", phase: "parsing"),
                       "la fase sullo schermo è quella della riga del server")

        fake.currentJob = ImportJobSnapshot(id: "j1", phase: "done", status: "done", error: nil)
        await vm.pollOnce(jobId: "j1")
        XCTAssertEqual(vm.state, .done(Self.unReport),
                       "a job done si mostra il report di §7.4, coi non riconosciuti dentro")
    }

    // MARK: - Gli errori, ciascuno distinto

    func testUploadFallitoNonCreaIlJob() async {
        let fake = Fake()
        fake.uploadFails = true
        let vm = makeVM(fake)

        await vm.start(zipData: Data("zip".utf8))
        guard case .failed(let key, _, let retryId) = vm.state else {
            return XCTFail("upload fallito = stato failed, era \(vm.state)")
        }
        XCTAssertEqual(key, "import.error.uploadFailed")
        XCTAssertNil(retryId, "nessun job è nato: il retry riparte dalla scelta del file")
        XCTAssertEqual(fake.creates, 0, "senza upload non si crea nessun job")
    }

    /// La sessione GoTrue morta sotto una cache che dice "loggato" (il caso TestFlight):
    /// il messaggio è "accedi di nuovo", non la verità tecnica della RLS, e senza detail —
    /// qui la frase localizzata basta da sola.
    func testSessioneScadutaHaLaFraseGiusta() async {
        let fake = Fake()
        fake.uploadSessionExpired = true
        let vm = makeVM(fake)

        await vm.start(zipData: Data("zip".utf8))
        guard case .failed(let key, let detail, let retryId) = vm.state else {
            return XCTFail("sessione scaduta = stato failed, era \(vm.state)")
        }
        XCTAssertEqual(key, "import.error.sessionExpired")
        XCTAssertNil(detail, "niente dettaglio tecnico: la frase localizzata basta")
        XCTAssertNil(retryId, "nessun job è nato: dopo il re-login si riparte dal file")
        XCTAssertEqual(fake.creates, 0, "senza upload non si crea nessun job")
    }

    func testFileIlleggibileNonToccaIlBackend() async {
        let fake = Fake()
        struct RottoFile: Error {}
        let vm = ImportViewModel(backend: fake, pollInterval: .seconds(600),
                                 readZip: { _ in throw RottoFile() })

        await vm.importFile(at: URL(fileURLWithPath: "/inesistente.zip"))
        guard case .failed(let key, _, _) = vm.state else {
            return XCTFail("file illeggibile = failed, era \(vm.state)")
        }
        XCTAssertEqual(key, "import.error.fileRead")
        XCTAssertEqual(fake.uploads, 0)
    }

    func testAlreadyRunningRiprendeIlJobEsistente() async {
        let fake = Fake()
        fake.createOutcome = ImportStartOutcome(ok: false, reason: "already_running")
        fake.currentJob = ImportJobSnapshot(id: "vecchio", phase: "resolving",
                                            status: "running", error: nil)
        let vm = makeVM(fake)

        await vm.start(zipData: Data("zip".utf8))
        XCTAssertEqual(vm.state, .running(jobId: "vecchio", phase: "resolving"),
                       "already_running non è un errore: si mostra l'import in corso")
    }

    func testEsitoNegativoDelServerEDettoConLaSuaRagione() async {
        let fake = Fake()
        fake.createOutcome = ImportStartOutcome(ok: false, reason: "upload_not_found")
        let vm = makeVM(fake)

        await vm.start(zipData: Data("zip".utf8))
        guard case .failed(let key, let detail, _) = vm.state else {
            return XCTFail("esito negativo = failed, era \(vm.state)")
        }
        XCTAssertEqual(key, "import.error.startFailed")
        XCTAssertEqual(detail, "upload_not_found", "la ragione del server si mostra, §7.4")
    }

    func testJobFallitoSulServerHaRetryCheRiparte() async {
        let fake = Fake()
        let vm = makeVM(fake)
        await vm.start(zipData: Data("zip".utf8))

        fake.currentJob = ImportJobSnapshot(id: "j1", phase: "writing", status: "failed",
                                            error: "guasto vero")
        await vm.pollOnce(jobId: "j1")
        guard case .failed(let key, let detail, let retryId) = vm.state else {
            return XCTFail("job failed = stato failed, era \(vm.state)")
        }
        XCTAssertEqual(key, "import.error.failed")
        XCTAssertEqual(detail, "guasto vero", "la verità tecnica non si abbellisce")
        XCTAssertEqual(retryId, "j1")

        await vm.retry()
        XCTAssertEqual(fake.retries, 1, "un job failed riparte con retry_import_job")
        XCTAssertEqual(vm.state, .running(jobId: "j1", phase: "writing"),
                       "la fase resta quella in cui era morto: il checkpoint sa da dove")
    }

    func testPollingPersoDiventaVisibileDopoLaSoglia() async {
        let fake = Fake()
        let vm = makeVM(fake)
        await vm.start(zipData: Data("zip".utf8))

        fake.jobReadFails = true
        for _ in 0..<5 { await vm.pollOnce(jobId: "j1") }
        guard case .failed(let key, _, let retryId) = vm.state else {
            return XCTFail("cinque errori di fila non sono più \"in corso\", era \(vm.state)")
        }
        XCTAssertEqual(key, "import.error.network")
        XCTAssertEqual(retryId, "j1")

        // Il retry di un polling perso RIPRENDE A GUARDARE: il job sul server non ha mai
        // smesso di lavorare, e non va toccato.
        fake.jobReadFails = false
        fake.currentJob = ImportJobSnapshot(id: "j1", phase: "recomputing", status: "running",
                                            error: nil)
        await vm.retry()
        XCTAssertEqual(fake.retries, 0, "nessuna retry_import_job: il job non era failed")
        XCTAssertEqual(vm.state, .running(jobId: "j1", phase: "recomputing"))
    }

    func testSottoSogliaSiRestaRunning() async {
        let fake = Fake()
        let vm = makeVM(fake)
        await vm.start(zipData: Data("zip".utf8))

        fake.jobReadFails = true
        await vm.pollOnce(jobId: "j1")
        guard case .running = vm.state else {
            return XCTFail("un singolo errore di polling non è un fallimento, era \(vm.state)")
        }
    }

    // MARK: - La ripresa all'apertura (§7.2: lo stato vive sul server)

    func testLoadExistingRiprendeUnJobAperto() async {
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j9", phase: "parsing", status: "running",
                                            error: nil)
        let vm = makeVM(fake)

        await vm.loadExisting()
        XCTAssertEqual(vm.state, .running(jobId: "j9", phase: "parsing"),
                       "la schermata riaperta ritrova l'import in corso")
    }

    func testLoadExistingConJobFailed() async {
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j9", phase: "writing", status: "failed",
                                            error: "morto ieri")
        let vm = makeVM(fake)

        await vm.loadExisting()
        guard case .failed(_, let detail, let retryId) = vm.state else {
            return XCTFail("l'ultimo job failed si mostra, era \(vm.state)")
        }
        XCTAssertEqual(detail, "morto ieri")
        XCTAssertEqual(retryId, "j9")
    }

    func testLoadExistingSenzaStoriaRestaSulleSorgenti() async {
        let fake = Fake()
        let vm = makeVM(fake)
        await vm.loadExisting()
        XCTAssertEqual(vm.state, .sources)
    }

    func testLoadExistingConJobDoneRiprendeIlReport() async {
        // Redesign 2.0: il report (e con lui l'inbox "Titoli da verificare") si RIPRENDE —
        // prima, chiuso il report, i non risolti diventavano irraggiungibili per sempre.
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j9", phase: "done", status: "done", error: nil)
        fake.report = Self.unReport
        let vm = makeVM(fake)
        await vm.loadExisting()
        XCTAssertEqual(vm.state, .done(Self.unReport))
    }

    func testLaRipresaDiUnJobDoneNonRifaIlSync() async {
        // La ripresa di un job già concluso non deve rinotificare `importJobCompleted`:
        // quei dati sono già nello specchio locale, un pull a ogni apertura sarebbe rumore.
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j9", phase: "done", status: "done", error: nil)
        fake.report = Self.unReport
        let vm = makeVM(fake)

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: .importJobCompleted, object: nil, queue: nil) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        await vm.loadExisting()
        XCTAssertFalse(notified, "la ripresa non è un completamento")
    }

    // MARK: - Il report

    func testReportIlleggibileNonEUnReportDiZeri() async {
        let fake = Fake()
        fake.reportFails = true
        let vm = makeVM(fake)
        await vm.start(zipData: Data("zip".utf8))

        fake.currentJob = ImportJobSnapshot(id: "j1", phase: "done", status: "done", error: nil)
        await vm.pollOnce(jobId: "j1")
        guard case .failed(let key, _, let retryId) = vm.state else {
            return XCTFail("report illeggibile = errore visibile, era \(vm.state)")
        }
        XCTAssertEqual(key, "import.error.reportFailed")
        XCTAssertEqual(retryId, "j1")

        // Il retry ricarica il REPORT (il job è done, non failed): niente secondo import.
        fake.reportFails = false
        fake.report = Self.unReport
        await vm.retry()
        XCTAssertEqual(fake.retries, 0)
        XCTAssertEqual(vm.state, .done(Self.unReport))
    }

    func testIlParserDelReportRifiutaUnJsonSenzaConteggi() {
        XCTAssertNil(ImportReport(json: ["serie_importate": 3]),
                     "senza episodi_importati non è un report: errore, non zeri")
        XCTAssertNotNil(ImportReport(json: ["episodi_importati": 0]))
    }

    func testGliStatiSerieSiDecodificanoEUnReportVecchioNonLiFingeAZero() {
        let nuovo = ImportReport(json: [
            "episodi_importati": 5,
            "stati_supportati": true,
            "stati_serie_importati": 104,
            "stati_serie_non_risolti": 3,
        ])
        XCTAssertEqual(nuovo?.statiSupportati, true)
        XCTAssertEqual(nuovo?.statiSerieImportati, 104)
        XCTAssertEqual(nuovo?.statiSerieNonRisolti, 3)

        // Un report generato prima di questa feature non ha i campi: `statiSupportati` false
        // è ciò che tiene la riga fuori dalla UI — l'assenza non è uno zero.
        let vecchio = ImportReport(json: ["episodi_importati": 5])
        XCTAssertEqual(vecchio?.statiSupportati, false)
    }

    func testIVotiSiDecodificanoEUnReportVecchioRestaNonImportato() {
        // §7.5, import-write v5: le stelle scritte in `user_ratings` si contano, comprese
        // quelle lasciate al voto già dato in app e quelle non risolte.
        let nuovo = ImportReport(json: [
            "episodi_importati": 5,
            "voti_stelle": 295,
            "voti_importati": true,
            "voti_stelle_importati": 290,
            "voti_stelle_gia_in_app": 3,
            "voti_stelle_non_risolti": 2,
        ])
        XCTAssertEqual(nuovo?.votiImportati, true)
        XCTAssertEqual(nuovo?.votiStelleImportati, 290)
        XCTAssertEqual(nuovo?.votiStelleGiaInApp, 3)
        XCTAssertEqual(nuovo?.votiStelleNonRisolti, 2)

        // Un report di un job vecchio non ha i campi nuovi: `votiImportati` false è ciò che
        // tiene in piedi la riga "non ancora importati" — la verità di quando è girato.
        let vecchio = ImportReport(json: ["episodi_importati": 5, "voti_stelle": 380])
        XCTAssertEqual(vecchio?.votiImportati, false)
        XCTAssertEqual(vecchio?.votiStelleImportati, 0)
    }

    func testIFavoritesSiDecodificanoEUnReportVecchioNonLiFinge() {
        // §7.1, import-write v6: i favorites riempiono solo gli slot liberi; slot pieni e già
        // favoriti non sono perdite, i film si dichiarano non supportati.
        let nuovo = ImportReport(json: [
            "episodi_importati": 5,
            "favorites_supportati": true,
            "favorites_importati": 3,
            "favorites_non_risolti": 1,
            "favorite_film_non_supportati": 2,
        ])
        XCTAssertEqual(nuovo?.favoritesSupportati, true)
        XCTAssertEqual(nuovo?.favoritesImportati, 3)
        XCTAssertEqual(nuovo?.favoritesNonRisolti, 1)
        XCTAssertEqual(nuovo?.favoriteFilmNonSupportati, 2)

        // Un report vecchio non ha i campi: `favoritesSupportati` false tiene la riga fuori
        // dalla UI — l'assenza non è uno zero.
        let vecchio = ImportReport(json: ["episodi_importati": 5])
        XCTAssertEqual(vecchio?.favoritesSupportati, false)
    }

    func testIFilmSiDecodificanoEUnReportVecchioNonLiFinge() {
        // §7.1, import-write v7: i film di v1 — visti in watch_events + lista "visti",
        // watchlist nella lista watchlist; exact-match+anno o niente.
        let nuovo = ImportReport(json: [
            "episodi_importati": 5,
            "film_supportati": true,
            "film_importati": 4,
            "film_watchlist_importati": 3,
            "film_non_risolti": 1,
        ])
        XCTAssertEqual(nuovo?.filmSupportati, true)
        XCTAssertEqual(nuovo?.filmImportati, 4)
        XCTAssertEqual(nuovo?.filmWatchlistImportati, 3)
        XCTAssertEqual(nuovo?.filmNonRisolti, 1)

        // Nei report VECCHI `film_supportati` era `false` hardcoded (0 film si dichiarava
        // "non supportato", non "non ne avevi"): la riga resta fuori, com'era allora.
        let vecchio = ImportReport(json: ["episodi_importati": 5, "film_supportati": false])
        XCTAssertEqual(vecchio?.filmSupportati, false)
        XCTAssertEqual(vecchio?.filmImportati, 0)
    }

    // MARK: - Risoluzione a mano (§7.4)

    func testLaRisoluzioneBatchRiapreIlJobUnaSolaVoltaETornaAGuardarlo() async {
        // Report a schermo per il job j9: tutte le associazioni devono riaprire QUEL job con
        // una sola chiamata, anche quando le serie da risolvere sono più di una.
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j9", phase: "done", status: "done", error: nil)
        fake.report = Self.unReport
        let vm = ImportViewModel(backend: fake, pollInterval: .seconds(60))
        await vm.pollOnce(jobId: "j9")
        guard case .done = vm.state else { return XCTFail("atteso .done, era \(vm.state)") }

        let resolutions = [
            ImportManualResolution(tvdbSeriesId: "901", tmdbShowId: 12345),
            ImportManualResolution(tvdbSeriesId: "902", tmdbShowId: 67890),
        ]
        let ok = await vm.resolveManually(resolutions)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.manualResolves.count, 1)
        XCTAssertEqual(fake.manualResolves.first?.jobId, "j9")
        XCTAssertEqual(fake.manualResolves.first?.resolutions, resolutions)
        // Il job è ripartito: l'oblò torna a guardarlo, non resta sul report vecchio.
        guard case .running(let jobId, let phase) = vm.state else {
            return XCTFail("atteso .running, era \(vm.state)")
        }
        XCTAssertEqual(jobId, "j9")
        XCTAssertEqual(phase, "resolving",
                       "la scelta della serie deve rifare la risoluzione per ID TVDB esatto")
        vm.stopPolling()
    }

    func testUnaRisoluzioneFallitaNonButtaViaIlReport() async {
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j9", phase: "done", status: "done", error: nil)
        fake.report = Self.unReport
        let vm = ImportViewModel(backend: fake, pollInterval: .seconds(60))
        await vm.pollOnce(jobId: "j9")

        fake.manualResolveFails = true
        let ok = await vm.resolveManually([
            ImportManualResolution(tvdbSeriesId: "901", tmdbShowId: 12345),
            ImportManualResolution(tvdbSeriesId: "902", tmdbShowId: 67890),
        ])
        XCTAssertFalse(ok)
        // L'errore è visibile nello sheet, e il report resta a schermo: un riaggancio
        // fallito non deve distruggere ciò che l'utente sta guardando.
        XCTAssertNotNil(vm.manualResolveError)
        guard case .done = vm.state else { return XCTFail("atteso .done, era \(vm.state)") }
    }

    func testSenzaUnReportAVideoLaRisoluzioneNonParte() async {
        let fake = Fake()
        let vm = ImportViewModel(backend: fake, pollInterval: .seconds(60))
        let ok = await vm.resolveManually([
            ImportManualResolution(tvdbSeriesId: "901", tmdbShowId: 12345),
        ])
        XCTAssertFalse(ok)
        XCTAssertEqual(fake.manualResolves.count, 0)
    }

    func testUnBatchVuotoODuplicatoNonAvviaLaRisoluzione() async {
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j9", phase: "done", status: "done", error: nil)
        fake.report = Self.unReport
        let vm = ImportViewModel(backend: fake, pollInterval: .seconds(60))
        await vm.pollOnce(jobId: "j9")

        let emptyAccepted = await vm.resolveManually([])
        let duplicateAccepted = await vm.resolveManually([
            ImportManualResolution(tvdbSeriesId: "901", tmdbShowId: 1),
            ImportManualResolution(tvdbSeriesId: "901", tmdbShowId: 2),
        ])
        XCTAssertFalse(emptyAccepted)
        XCTAssertFalse(duplicateAccepted)
        XCTAssertEqual(fake.manualResolves.count, 0)
    }

    func testLUnresolvedPortaLaManigliaTvdbDalJson() {
        let report = ImportReport(json: [
            "episodi_importati": 1,
            "non_riconosciuti_episodi": 2,
            "non_riconosciuti_elenco": [
                ["titolo": "X Factor IT", "episodi": 2, "motivo": "catalogo: not_found",
                 "tvdb_series_id": "75530"],
                ["titolo": "Senza id", "episodi": 1, "motivo": "id serie mancante"],
            ],
        ])
        XCTAssertEqual(report?.nonRiconosciutiElenco.first?.tvdbSeriesId, "75530")
        // Senza id la maniglia non c'è: il pulsante Risolvi non esiste per quella riga.
        XCTAssertNil(report?.nonRiconosciutiElenco.last?.tvdbSeriesId)
    }

    // MARK: - Redesign 2.0: inbox, progresso, esclusione

    func testLInboxFondeSerieStatiEFilm() {
        let report = ImportReport(json: [
            "episodi_importati": 1,
            "non_riconosciuti_elenco": [
                ["titolo": "The Office", "episodi": 201, "motivo": "catalogo: not_found",
                 "tvdb_series_id": "73244"],
            ],
            "stati_non_risolti_elenco": [
                // Stessa serie degli episodi: NON deve fare una seconda card.
                ["titolo": "The Office", "stato": "watchlist", "motivo": "catalogo: not_found",
                 "tvdb_series_id": "73244"],
                ["titolo": "Solo stato", "stato": "archived", "motivo": "catalogo: not_found",
                 "tvdb_series_id": "999"],
            ],
            "film_non_risolti_elenco": [
                ["titolo": "Un film", "tipo": "seen", "motivo": "film: anno mancante",
                 "tvtime_movie_uuid": "uuid-1"],
            ],
        ])
        let items = report?.reviewItems ?? []
        XCTAssertEqual(items.count, 3, "una card per serie, una per lo stato orfano, una film")
        XCTAssertEqual(items.filter(\.isMovie).count, 1)
        XCTAssertTrue(items.first { $0.titolo == "The Office" }?.isResolvable ?? false)
        // Il film non ha risoluzione a mano: solo esclusione.
        XCTAssertFalse(items.first { $0.isMovie }?.isResolvable ?? true)
    }

    func testIlProgressoVieneDaiContatoriVeri() {
        // Fase di risoluzione a metà: 9.000 eventi processati su 18.000, niente altro.
        let snapshot = ImportJobSnapshot(
            id: "j1", phase: "resolving", status: "running", error: nil,
            totals: ["events": 18_000, "resolved": 8_500, "unresolved": 500])
        let progress = snapshot.progress
        XCTAssertEqual(progress.processedEpisodes, 9_000)
        XCTAssertEqual(progress.totalEpisodes, 18_000)
        // 0.15 + 0.60 * 0.5 = 0.45
        XCTAssertEqual(progress.fraction, 0.45, accuracy: 0.001)

        // Scrittura a metà: banda 0.78–0.96.
        let writing = ImportJobSnapshot(
            id: "j1", phase: "writing", status: "running", error: nil,
            totals: ["events": 18_000, "staged_rows": 20_000,
                     "written": 9_000, "already_present": 1_000])
        XCTAssertEqual(writing.progress.fraction, 0.78 + 0.18 * 0.5, accuracy: 0.001)
    }

    func testLEsclusioneChiamaIlBackendERileggeIlReport() async {
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j1", phase: "done", status: "done", error: nil)
        fake.report = Self.unReport
        let vm = makeVM(fake)
        await vm.loadExisting()

        // Dopo l'esclusione il server non conta più il titolo: il report riletto è pulito.
        let pulito = ImportReport(
            episodiImportati: 42, serieImportate: 3, dal: nil, al: nil,
            nonRiconosciutiEpisodi: 0, nonRiconosciutiSerie: 0, nonRiconosciutiElenco: [],
            votiStelle: 0, votiReaction: 0, votiImportati: true)
        fake.report = pulito

        let item = ImportReviewItem(source: .series(tvdbSeriesId: "901"),
                                    titolo: "Sconosciuta", episodi: 5,
                                    motivo: "no match", statoRichiesto: nil)
        let ok = await vm.excludeItems([item])
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.excludes.count, 1)
        XCTAssertEqual(fake.excludes.first?.seriesIds, ["901"])
        XCTAssertEqual(vm.state, .done(pulito), "il report a schermo è quello riletto")
    }

    /// Redesign 2.0: chi escludi resta nel report — ma fuori dall'inbox, che è l'elenco di
    /// quello che c'è ancora da fare.
    func testGliEsclusiRestanoNelReportMaNonNellInbox() {
        let json: [String: Any] = [
            "episodi_importati": 10,
            "non_riconosciuti_elenco": [
                ["titolo": "Da verificare", "episodi": 3, "motivo": "catalogo: not_found",
                 "tvdb_series_id": "900", "escluso": false],
                ["titolo": "Escluso da me", "episodi": 1, "motivo": "escluso: utente",
                 "tvdb_series_id": "901", "escluso": true]
            ]
        ]
        let report = ImportReport(json: json)

        XCTAssertEqual(report?.leftOutItems.count, 2, "il report li mostra entrambi")
        XCTAssertEqual(report?.reviewItems.map(\.titolo), ["Da verificare"],
                       "l'inbox mostra solo ciò che è ancora da verificare")
        XCTAssertEqual(report?.leftOutItems.last?.escluso, true)
        XCTAssertEqual(report?.leftOutItems.last?.isResolvable, false,
                       "un escluso non si riapre dalla card: è una decisione già presa")
    }

    /// I film non risolti portano anno e data di visione: senza, la card del report non
    /// saprebbe dire quale film è.
    func testIlFilmNonRisoltoPortaAnnoEDataDiVisione() {
        let json: [String: Any] = [
            "episodi_importati": 0,
            "film_supportati": true,
            "film_non_risolti_elenco": [
                ["titolo": "Sotto il cielo di Kyoto", "tipo": "seen", "motivo": "film: not_found",
                 "tvtime_movie_uuid": "u-1", "anno": "2018", "visto_il": "2019-03-12 21:00:00"]
            ]
        ]
        let report = ImportReport(json: json)
        let item = report?.leftOutItems.first

        XCTAssertEqual(item?.anno, "2018")
        XCTAssertEqual(item?.vistoIl, "2019-03-12 21:00:00")
        XCTAssertEqual(item?.isMovie, true)
    }

    /// Un report vecchio non ha il campo: nessuno è escluso, e l'inbox resta quella di prima.
    func testUnReportVecchioNonInventaEsclusioni() {
        let json: [String: Any] = [
            "episodi_importati": 1,
            "non_riconosciuti_elenco": [
                ["titolo": "Serie", "episodi": 2, "motivo": "catalogo: not_found",
                 "tvdb_series_id": "900"]
            ]
        ]
        let report = ImportReport(json: json)

        XCTAssertEqual(report?.leftOutItems.first?.escluso, false)
        XCTAssertEqual(report?.reviewItems.count, 1)
    }

    func testLEsclusioneSenzaManiglieNonChiamaIlServer() async {
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j1", phase: "done", status: "done", error: nil)
        fake.report = Self.unReport
        let vm = makeVM(fake)
        await vm.loadExisting()

        // Un film senza uuid non ha maniglia: la chiamata non parte.
        let item = ImportReviewItem(source: .movie(tvtimeMovieUuid: nil),
                                    titolo: "Film orfano", episodi: 0,
                                    motivo: "x", statoRichiesto: nil)
        let ok = await vm.excludeItems([item])
        XCTAssertFalse(ok)
        XCTAssertEqual(fake.excludes.count, 0)
    }
}
