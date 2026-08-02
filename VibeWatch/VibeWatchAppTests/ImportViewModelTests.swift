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
        var jobReadFails = false
        var reportFails = false
        var createOutcome: ImportStartOutcome?
        var retryOutcome = ImportStartOutcome(ok: true)

        private(set) var uploads = 0
        private(set) var creates = 0
        private(set) var retries = 0

        func uploadZip(_ data: Data) async throws -> String {
            uploads += 1
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
    }

    private static let unReport = ImportReport(
        episodiImportati: 42, serieImportate: 3, dal: "2020-01-01", al: "2024-06-01",
        nonRiconosciutiEpisodi: 5, nonRiconosciutiSerie: 1,
        nonRiconosciutiElenco: [.init(titolo: "Sconosciuta", episodi: 5, motivo: "no match")],
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

    func testLoadExistingConJobDoneRestaSulleSorgenti() async {
        // Il report di un import già visto non si ripropone: la schermata serve al prossimo.
        let fake = Fake()
        fake.currentJob = ImportJobSnapshot(id: "j9", phase: "done", status: "done", error: nil)
        let vm = makeVM(fake)
        await vm.loadExisting()
        XCTAssertEqual(vm.state, .sources)
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
}
