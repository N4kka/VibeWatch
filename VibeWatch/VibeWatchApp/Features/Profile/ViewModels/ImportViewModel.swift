import Foundation

// MARK: - Modelli (SPEC v3 §7)

/// L'esito di `create_import_job` / `retry_import_job`. Gli esiti prevedibili viaggiano come
/// risposta (`reason`), non come eccezione: `already_running` non è un guasto, è la ragione
/// per cui la schermata riprende il job esistente.
struct ImportStartOutcome: Equatable {
    let ok: Bool
    let jobId: String?
    let reason: String?

    init(ok: Bool, jobId: String? = nil, reason: String? = nil) {
        self.ok = ok
        self.jobId = jobId
        self.reason = reason
    }

    init?(json: [String: Any]) {
        guard let ok = json["ok"] as? Bool else { return nil }
        self.ok = ok
        self.jobId = json["job_id"] as? String
        self.reason = json["reason"] as? String
    }
}

/// La riga di `import_jobs` che il polling legge. Lo stato vive sul server (§7.2): il client
/// la guarda e basta, le fasi le muove il driver del cron.
struct ImportJobSnapshot: Decodable, Equatable {
    let id: String
    let phase: String
    let status: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, phase, status, error
    }

    var isOpen: Bool { status == "running" || status == "paused" }
}

/// Il report di §7.4, così come `import_report` lo costruisce. I nomi restano quelli del
/// server: sono il contratto, e un sinonimo qui sarebbe una seconda cosa da tenere allineata.
struct ImportReport: Equatable {
    struct Unresolved: Equatable {
        let titolo: String
        let episodi: Int
        let motivo: String
        /// L'id TVDB della serie nell'export: è la maniglia della risoluzione a mano (§7.4).
        /// Nullo per le righe che non ce l'hanno — lì il pulsante "Risolvi" non esiste.
        let tvdbSeriesId: String?
    }

    let episodiImportati: Int
    let serieImportate: Int
    let dal: String?
    let al: String?
    let nonRiconosciutiEpisodi: Int
    let nonRiconosciutiSerie: Int
    let nonRiconosciutiElenco: [Unresolved]
    let votiStelle: Int
    let votiReaction: Int
    /// §7.5: `true` quando ogni stella è passata dalla pipeline nuova (import-write v5).
    /// Un job vecchio resta `false` e mostra la riga "non ancora importati" di sempre.
    let votiImportati: Bool
    let votiStelleImportati: Int
    let votiStelleGiaInApp: Int
    let votiStelleNonRisolti: Int
    /// §7.1: gli stati per-serie (watchlist e archivio). `statiSupportati` distingue un report
    /// di un job vecchio (campi assenti: la riga non si mostra) da zeri veri.
    let statiSupportati: Bool
    let statiSerieImportati: Int
    let statiSerieNonRisolti: Int
    /// §7.1: i Favorites — riempiono solo gli slot liberi (slot pieni e già favoriti non sono
    /// perdite e non allarmano); i favorite film si dichiarano non supportati.
    let favoritesSupportati: Bool
    let favoritesImportati: Int
    let favoritesNonRisolti: Int
    let favoriteFilmNonSupportati: Int
    /// §7.1: i film di v1 (visti → watch_events + lista "visti"; watchlist → lista watchlist).
    /// `filmSupportati` distingue un report di un job vecchio (campi assenti) da zeri veri.
    let filmSupportati: Bool
    let filmImportati: Int
    let filmWatchlistImportati: Int
    let filmNonRisolti: Int

    init?(json: [String: Any]) {
        // Un report senza il conteggio principale non è un report: meglio un errore visibile
        // che una schermata di zeri (§7.4).
        guard let episodi = json["episodi_importati"] as? Int else { return nil }
        episodiImportati = episodi
        serieImportate = json["serie_importate"] as? Int ?? 0
        dal = json["dal"] as? String
        al = json["al"] as? String
        nonRiconosciutiEpisodi = json["non_riconosciuti_episodi"] as? Int ?? 0
        nonRiconosciutiSerie = json["non_riconosciuti_serie"] as? Int ?? 0
        nonRiconosciutiElenco = (json["non_riconosciuti_elenco"] as? [[String: Any]] ?? [])
            .compactMap { row in
                guard let titolo = row["titolo"] as? String else { return nil }
                return Unresolved(titolo: titolo,
                                  episodi: row["episodi"] as? Int ?? 0,
                                  motivo: row["motivo"] as? String ?? "",
                                  tvdbSeriesId: row["tvdb_series_id"] as? String)
            }
        votiStelle = json["voti_stelle"] as? Int ?? 0
        votiReaction = json["voti_reaction"] as? Int ?? 0
        votiImportati = json["voti_importati"] as? Bool ?? false
        votiStelleImportati = json["voti_stelle_importati"] as? Int ?? 0
        votiStelleGiaInApp = json["voti_stelle_gia_in_app"] as? Int ?? 0
        votiStelleNonRisolti = json["voti_stelle_non_risolti"] as? Int ?? 0
        statiSupportati = json["stati_supportati"] as? Bool ?? false
        statiSerieImportati = json["stati_serie_importati"] as? Int ?? 0
        statiSerieNonRisolti = json["stati_serie_non_risolti"] as? Int ?? 0
        favoritesSupportati = json["favorites_supportati"] as? Bool ?? false
        favoritesImportati = json["favorites_importati"] as? Int ?? 0
        favoritesNonRisolti = json["favorites_non_risolti"] as? Int ?? 0
        favoriteFilmNonSupportati = json["favorite_film_non_supportati"] as? Int ?? 0
        // `film_supportati` era `false` hardcoded nei report vecchi: il ?? false li lascia
        // senza riga film, che è la verità di quando sono girati.
        filmSupportati = json["film_supportati"] as? Bool ?? false
        filmImportati = json["film_importati"] as? Int ?? 0
        filmWatchlistImportati = json["film_watchlist_importati"] as? Int ?? 0
        filmNonRisolti = json["film_non_risolti"] as? Int ?? 0
    }

    init(episodiImportati: Int, serieImportate: Int, dal: String?, al: String?,
         nonRiconosciutiEpisodi: Int, nonRiconosciutiSerie: Int,
         nonRiconosciutiElenco: [Unresolved], votiStelle: Int, votiReaction: Int,
         votiImportati: Bool, votiStelleImportati: Int = 0, votiStelleGiaInApp: Int = 0,
         votiStelleNonRisolti: Int = 0, statiSupportati: Bool = false,
         statiSerieImportati: Int = 0, statiSerieNonRisolti: Int = 0,
         favoritesSupportati: Bool = false, favoritesImportati: Int = 0,
         favoritesNonRisolti: Int = 0, favoriteFilmNonSupportati: Int = 0,
         filmSupportati: Bool = false, filmImportati: Int = 0,
         filmWatchlistImportati: Int = 0, filmNonRisolti: Int = 0) {
        self.episodiImportati = episodiImportati
        self.serieImportate = serieImportate
        self.dal = dal
        self.al = al
        self.nonRiconosciutiEpisodi = nonRiconosciutiEpisodi
        self.nonRiconosciutiSerie = nonRiconosciutiSerie
        self.nonRiconosciutiElenco = nonRiconosciutiElenco
        self.votiStelle = votiStelle
        self.votiReaction = votiReaction
        self.votiImportati = votiImportati
        self.votiStelleImportati = votiStelleImportati
        self.votiStelleGiaInApp = votiStelleGiaInApp
        self.votiStelleNonRisolti = votiStelleNonRisolti
        self.statiSupportati = statiSupportati
        self.statiSerieImportati = statiSerieImportati
        self.statiSerieNonRisolti = statiSerieNonRisolti
        self.favoritesSupportati = favoritesSupportati
        self.favoritesImportati = favoritesImportati
        self.favoritesNonRisolti = favoritesNonRisolti
        self.favoriteFilmNonSupportati = favoriteFilmNonSupportati
        self.filmSupportati = filmSupportati
        self.filmImportati = filmImportati
        self.filmWatchlistImportati = filmWatchlistImportati
        self.filmNonRisolti = filmNonRisolti
    }
}

// MARK: - La dipendenza, isolata (modello UsernameBackend)

@MainActor
protocol ImportBackend {
    func uploadZip(_ data: Data) async throws -> String
    func createJob(storagePath: String) async throws -> ImportStartOutcome
    func retryJob(id: String) async throws -> ImportStartOutcome
    func latestJob() async throws -> ImportJobSnapshot?
    func job(id: String) async throws -> ImportJobSnapshot?
    func report(jobId: String) async throws -> ImportReport
    /// §7.4: "questa serie dell'export È questa serie TMDB". Riapre la risoluzione lato server.
    func manualResolve(jobId: String, tvdbSeriesId: String, tmdbShowId: Int) async throws
}

@MainActor
struct SupabaseImportBackend: ImportBackend {
    func uploadZip(_ data: Data) async throws -> String {
        try await SupabaseService.shared.uploadImportZip(data)
    }
    func createJob(storagePath: String) async throws -> ImportStartOutcome {
        try await SupabaseService.shared.createImportJob(storagePath: storagePath)
    }
    func retryJob(id: String) async throws -> ImportStartOutcome {
        try await SupabaseService.shared.retryImportJob(id: id)
    }
    func latestJob() async throws -> ImportJobSnapshot? {
        try await SupabaseService.shared.latestImportJob()
    }
    func job(id: String) async throws -> ImportJobSnapshot? {
        try await SupabaseService.shared.importJob(id: id)
    }
    func report(jobId: String) async throws -> ImportReport {
        try await SupabaseService.shared.importReport(jobId: jobId)
    }
    func manualResolve(jobId: String, tvdbSeriesId: String, tmdbShowId: Int) async throws {
        try await SupabaseService.shared.manualResolveImport(
            jobId: jobId, tvdbSeriesId: tvdbSeriesId, tmdbShowId: tmdbShowId)
    }
}

// MARK: - ImportViewModel

/// SPEC v3 §7 — il flusso visto dal client: scegli lo ZIP, caricalo, crea il job, e da lì in
/// poi GUARDA. Le fasi le muove il server (il driver del cron), quindi l'app si può chiudere:
/// questa schermata è un oblò, non un motore.
@MainActor
final class ImportViewModel: ObservableObject {

    /// Ogni stato ha una resa distinta: un errore non deve mai travestirsi da "vuoto" né da
    /// "in corso" (la famiglia di fallimenti silenziosi in testa a spec-v3-STATO.md).
    enum FlowState: Equatable {
        /// La lista delle sorgenti. Oggi una: TV Time (.zip).
        case sources
        /// Lo ZIP sta salendo. È l'unico tratto che richiede l'app aperta.
        case uploading
        /// Il job esiste e il server lavora. Da qui in poi l'app si può chiudere (§7.2).
        case running(jobId: String, phase: String)
        /// Il report di §7.4.
        case done(ImportReport)
        /// `messageKey` è una chiave di localizzazione; `detail` è la verità tecnica del
        /// server, mostrata piccola ma mostrata (§7.4: non si abbellisce). `retryJobId` nullo
        /// = fallito prima che il job esistesse: si riparte dalla scelta del file.
        case failed(messageKey: String, detail: String?, retryJobId: String?)
    }

    @Published private(set) var state: FlowState = .sources

    private let backend: any ImportBackend
    private let pollInterval: Duration
    /// Legge lo ZIP dal picker. Iniettabile: i test non hanno file veri.
    private let readZip: @Sendable (URL) throws -> Data
    private var pollTask: Task<Void, Never>?
    /// Errori di POLLING consecutivi (non del job): oltre la soglia si smette di fingere che
    /// vada tutto bene. Il job sul server intanto prosegue — il retry qui riprende a guardare.
    private var pollFailures = 0
    private static let maxPollFailures = 5

    init(backend: (any ImportBackend)? = nil,
         pollInterval: Duration = .seconds(4),
         readZip: (@Sendable (URL) throws -> Data)? = nil) {
        self.backend = backend ?? SupabaseImportBackend()
        self.pollInterval = pollInterval
        self.readZip = readZip ?? { url in
            // Il picker consegna un URL security-scoped: senza start/stop la lettura fallisce
            // con un "permission denied" che sembra un file rotto.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url)
        }
    }

    deinit { pollTask?.cancel() }

    /// All'apertura: l'import in corso (o l'ultimo fallito) vive sul server e va ritrovato.
    /// Un errore di rete qui lascia la lista delle sorgenti: da lì ogni strada è ancora
    /// percorribile, e un doppio avvio muore comunque su `already_running`.
    func loadExisting() async {
        guard case .sources = state else { return }
        guard let job = try? await backend.latestJob() else { return }
        if job.isOpen {
            startPolling(jobId: job.id, phase: job.phase)
        } else if job.status == "failed" {
            state = .failed(messageKey: "import.error.failed", detail: job.error,
                            retryJobId: job.id)
        }
        // `done`: nessuna ripresa — il report si è già visto, la schermata riparte dalle
        // sorgenti per l'import successivo.
    }

    /// Dal picker. La lettura sta fuori dal main actor: uno ZIP GDPR è decine di MB.
    func importFile(at url: URL) async {
        state = .uploading
        let read = readZip
        do {
            let data = try await Task.detached(priority: .userInitiated) { try read(url) }.value
            await start(zipData: data)
        } catch {
            state = .failed(messageKey: "import.error.fileRead",
                            detail: error.localizedDescription, retryJobId: nil)
        }
    }

    func start(zipData: Data) async {
        state = .uploading
        do {
            let path = try await backend.uploadZip(zipData)
            let outcome = try await backend.createJob(storagePath: path)
            if outcome.ok, let jobId = outcome.jobId {
                startPolling(jobId: jobId, phase: "uploaded")
            } else if outcome.reason == "already_running" {
                // Non è un errore: c'è già un import in corso e la schermata deve mostrarLO.
                await resumeOpenJob()
            } else {
                state = .failed(messageKey: "import.error.startFailed",
                                detail: outcome.reason, retryJobId: nil)
            }
        } catch {
            state = .failed(messageKey: "import.error.uploadFailed",
                            detail: error.localizedDescription, retryJobId: nil)
        }
    }

    /// Dallo stato `failed`. Due casi diversi con lo stesso pulsante: un job fallito sul
    /// server riparte con `retry_import_job` (checkpoint, §7.2); un polling perso riprende
    /// a guardare un job che magari non ha mai smesso di lavorare.
    func retry() async {
        guard case .failed(_, _, let retryJobId) = state else { return }
        guard let jobId = retryJobId else {
            state = .sources
            return
        }
        do {
            guard let job = try await backend.job(id: jobId) else {
                state = .sources
                return
            }
            if job.status == "failed" {
                let outcome = try await backend.retryJob(id: jobId)
                if outcome.ok {
                    startPolling(jobId: jobId, phase: job.phase)
                } else {
                    state = .failed(messageKey: "import.error.failed",
                                    detail: outcome.reason, retryJobId: jobId)
                }
            } else if job.isOpen {
                startPolling(jobId: jobId, phase: job.phase)
            } else {
                await showReport(jobId: jobId)
            }
        } catch {
            state = .failed(messageKey: "import.error.network",
                            detail: error.localizedDescription, retryJobId: jobId)
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Il polling

    private func startPolling(jobId: String, phase: String) {
        pollFailures = 0
        state = .running(jobId: jobId, phase: phase)
        pollTask?.cancel()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce(jobId: jobId)
                guard case .running = self.state else { return }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// Un giro di polling. Interno ma non privato: i test lo chiamano direttamente per non
    /// dover aspettare l'orologio.
    func pollOnce(jobId: String) async {
        do {
            guard let job = try await backend.job(id: jobId) else {
                // Sparito da sotto la RLS: non è "in corso", e dirlo è meglio che girare a vuoto.
                state = .failed(messageKey: "import.error.failed", detail: "job_not_found",
                                retryJobId: nil)
                return
            }
            pollFailures = 0
            if job.status == "failed" {
                state = .failed(messageKey: "import.error.failed", detail: job.error,
                                retryJobId: job.id)
            } else if job.phase == "done" || job.status == "done" {
                await showReport(jobId: job.id)
            } else {
                state = .running(jobId: job.id, phase: job.phase)
            }
        } catch {
            pollFailures += 1
            if pollFailures >= Self.maxPollFailures {
                state = .failed(messageKey: "import.error.network",
                                detail: error.localizedDescription, retryJobId: jobId)
            }
            // Sotto soglia: si resta `running` e si riprova — il server non ha detto niente
            // di male, è la nostra linea che balbetta.
        }
    }

    private func resumeOpenJob() async {
        do {
            guard let job = try await backend.latestJob(), job.isOpen else {
                state = .failed(messageKey: "import.error.startFailed",
                                detail: "already_running", retryJobId: nil)
                return
            }
            startPolling(jobId: job.id, phase: job.phase)
        } catch {
            state = .failed(messageKey: "import.error.network",
                            detail: error.localizedDescription, retryJobId: nil)
        }
    }

    private func showReport(jobId: String) async {
        do {
            state = .done(try await backend.report(jobId: jobId))
            doneJobId = jobId
        } catch {
            // Il lavoro è fatto ma il report non si legge: dirlo, con la ripresa che
            // ricarica il report e non certo l'import.
            state = .failed(messageKey: "import.error.reportFailed",
                            detail: error.localizedDescription, retryJobId: jobId)
        }
    }

    // MARK: - Risoluzione a mano (§7.4)

    /// Il job del report a schermo: serve alla risoluzione a mano, che riapre QUEL job.
    /// Lo stato `.done` porta solo il report — aggiungerci l'id avrebbe toccato ogni test
    /// dell'oblò per un dato che usa una feature sola.
    private(set) var doneJobId: String?

    /// L'errore dell'ultima risoluzione a mano, per lo sheet. Distinto dallo stato del
    /// flusso: un riaggancio fallito non deve buttare via il report che l'utente sta
    /// guardando.
    @Published var manualResolveError: String?

    /// "Questa serie dell'export È questa serie TMDB": il server ritenta gli episodi per il
    /// loro ID TVDB esatto e riapre il job; qui si torna a guardarlo. `false` = niente
    /// da riprendere o errore, con la ragione in `manualResolveError`.
    func resolveManually(tvdbSeriesId: String, tmdbShowId: Int) async -> Bool {
        guard case .done = state, let jobId = doneJobId else { return false }
        manualResolveError = nil
        do {
            try await backend.manualResolve(
                jobId: jobId, tvdbSeriesId: tvdbSeriesId, tmdbShowId: tmdbShowId)
            startPolling(jobId: jobId, phase: "resolving")
            return true
        } catch {
            manualResolveError = error.localizedDescription
            return false
        }
    }
}
