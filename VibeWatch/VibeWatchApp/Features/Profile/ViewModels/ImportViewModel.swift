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
    /// I contatori veri di `import_jobs.totals` (events, resolved, written…). Le fasi li
    /// aggiornano a ogni giro: sono ciò che rende il progresso una lettura, non una stima.
    var totals: [String: Double] = [:]

    enum CodingKeys: String, CodingKey {
        case id, phase, status, error, totals
    }

    init(id: String, phase: String, status: String, error: String?,
         totals: [String: Double] = [:]) {
        self.id = id
        self.phase = phase
        self.status = status
        self.error = error
        self.totals = totals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        phase = try container.decode(String.self, forKey: .phase)
        status = try container.decode(String.self, forKey: .status)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        // `totals` è jsonb libero: dentro ci sono numeri ma anche stringhe (user_language,
        // user_timezone). Si tengono i numeri e si lascia cadere il resto senza far fallire
        // l'intera riga — un totale illeggibile non deve spegnere il polling.
        let raw = (try? container.decodeIfPresent([String: LossyNumber].self, forKey: .totals))
            ?? nil
        totals = (raw ?? [:]).compactMapValues(\.value)
    }

    var isOpen: Bool { status == "running" || status == "paused" }

    var progress: ImportProgress { ImportProgress(phase: phase, totals: totals) }

    /// Un valore jsonb che vorremmo numerico ma può non esserlo: `value` nullo = non lo era.
    struct LossyNumber: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let double = try? single.decode(Double.self) { value = double } else { value = nil }
        }
    }
}

/// Il progresso REALE dell'import, letto dai contatori delle fasi — non più la rampa a
/// scatti derivata dal solo nome della fase. Le bande per fase riflettono il costo osservato:
/// la risoluzione è di gran lunga il tratto più lungo (una chiamata TMDB per episodio nuovo).
struct ImportProgress: Equatable {
    /// 0…1 sull'intero import.
    let fraction: Double
    /// "X di Y episodi" della card: eventi processati dalla risoluzione. Nulli quando la
    /// fase corrente non ha ancora un contatore onesto da mostrare.
    let processedEpisodes: Int?
    let totalEpisodes: Int?

    init(phase: String, totals: [String: Double]) {
        let events = Int(totals["events"] ?? 0)

        func frac(_ done: Double, of total: Double) -> Double {
            total > 0 ? min(1, max(0, done / total)) : 0
        }

        switch phase {
        case "uploaded":
            fraction = 0.05
            processedEpisodes = nil
            totalEpisodes = nil
        case "parsing":
            fraction = 0.10
            processedEpisodes = nil
            totalEpisodes = nil
        case "resolving":
            // Tutte le code della fase 3 contano: eventi, stati, favorites, film.
            let doneUnits = (totals["resolved"] ?? 0) + (totals["unresolved"] ?? 0)
                + (totals["statuses_resolved"] ?? 0) + (totals["statuses_unresolved"] ?? 0)
                + (totals["favorites_resolved"] ?? 0) + (totals["favorites_unresolved"] ?? 0)
                + (totals["movies_resolved"] ?? 0) + (totals["movies_unresolved"] ?? 0)
            let totalUnits = Double(events) + (totals["series_statuses"] ?? 0)
                + (totals["favorites"] ?? 0)
                + (totals["movies_seen"] ?? 0) + (totals["movies_watchlist"] ?? 0)
            fraction = 0.15 + 0.60 * frac(doneUnits, of: totalUnits)
            let processed = Int((totals["resolved"] ?? 0) + (totals["unresolved"] ?? 0))
            processedEpisodes = events > 0 ? min(processed, events) : nil
            totalEpisodes = events > 0 ? events : nil
        case "writing":
            let written = (totals["written"] ?? 0) + (totals["already_present"] ?? 0)
                + (totals["not_written"] ?? 0)
            fraction = 0.78 + 0.18 * frac(written, of: totals["staged_rows"] ?? 0)
            processedEpisodes = events > 0 ? events : nil
            totalEpisodes = events > 0 ? events : nil
        case "recomputing":
            fraction = 0.97
            processedEpisodes = events > 0 ? events : nil
            totalEpisodes = events > 0 ? events : nil
        case "done":
            fraction = 1
            processedEpisodes = events > 0 ? events : nil
            totalEpisodes = events > 0 ? events : nil
        default:
            fraction = 0.05
            processedEpisodes = nil
            totalEpisodes = nil
        }
    }
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
        /// Escluso dall'utente durante la verifica. Resta nel report — sparire senza traccia
        /// sarebbe peggio di restare — ma fuori dai conteggi di ciò che c'è ancora da fare.
        var escluso: Bool = false
    }

    /// Uno stato per-serie (watchlist/archivio) rimasto senza catalogo: stessa maniglia
    /// delle serie (`tvdb_series_id`), quindi stessa risoluzione a mano.
    struct UnresolvedStatus: Equatable {
        let titolo: String
        let stato: String?
        let motivo: String
        let tvdbSeriesId: String?
        var escluso: Bool = false
    }

    /// Un film di v1 non riconosciuto. Nessun id esterno: la sola azione possibile è
    /// l'esclusione, e la maniglia è l'uuid TV Time che il report porta con la riga.
    struct UnresolvedMovie: Equatable {
        let titolo: String
        let tipo: String?
        let motivo: String
        let tvtimeMovieUuid: String?
        var escluso: Bool = false
        /// Dall'export: servono alla card del report per dire QUALE film non è passato.
        var anno: String? = nil
        var vistoIl: String? = nil
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
    var statiNonRisoltiElenco: [UnresolvedStatus] = []
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
    var filmNonRisoltiElenco: [UnresolvedMovie] = []
    /// Episodi di serie confermate a mano i cui numeri dell'export non esistono nella
    /// struttura TMDB: perdita dichiarata dal server, non più card eterne nell'inbox.
    var episodiFuoriStruttura: Int = 0

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
                                  tvdbSeriesId: row["tvdb_series_id"] as? String,
                                  escluso: row["escluso"] as? Bool ?? false)
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
        statiNonRisoltiElenco = (json["stati_non_risolti_elenco"] as? [[String: Any]] ?? [])
            .compactMap { row in
                guard let titolo = row["titolo"] as? String else { return nil }
                return UnresolvedStatus(titolo: titolo,
                                        stato: row["stato"] as? String,
                                        motivo: row["motivo"] as? String ?? "",
                                        tvdbSeriesId: row["tvdb_series_id"] as? String,
                                        escluso: row["escluso"] as? Bool ?? false)
            }
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
        filmNonRisoltiElenco = (json["film_non_risolti_elenco"] as? [[String: Any]] ?? [])
            .compactMap { row in
                guard let titolo = row["titolo"] as? String else { return nil }
                return UnresolvedMovie(titolo: titolo,
                                       tipo: row["tipo"] as? String,
                                       motivo: row["motivo"] as? String ?? "",
                                       tvtimeMovieUuid: row["tvtime_movie_uuid"] as? String,
                                       escluso: row["escluso"] as? Bool ?? false,
                                       anno: row["anno"] as? String,
                                       vistoIl: row["visto_il"] as? String)
            }
        episodiFuoriStruttura = json["episodi_fuori_struttura"] as? Int ?? 0
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

// MARK: - Titoli da verificare (redesign 2.0)

/// Una card dell'inbox "Titoli da verificare": la vista unificata di ciò che l'import non ha
/// riconosciuto — serie (eventi e stati per-serie condividono la maniglia `tvdb_series_id`)
/// e film (solo esclusione: non esiste una risoluzione a mano per titolo lato server).
struct ImportReviewItem: Identifiable, Equatable {
    enum Source: Equatable {
        case series(tvdbSeriesId: String?)
        case movie(tvtimeMovieUuid: String?)
    }

    let source: Source
    let titolo: String
    /// Episodi visti nell'export (0 per gli stati puri e per i film).
    let episodi: Int
    let motivo: String
    /// Lo stato per-serie richiesto dall'export (watchlist/archivio), quando la card nasce
    /// da un `user_show_special_status` e non da episodi visti.
    let statoRichiesto: String?
    /// Escluso dall'utente: fuori dall'inbox, ma nel report resta visibile col suo motivo.
    var escluso: Bool = false
    /// Solo per i film, e solo quando l'export li ha: anno di uscita e data di visione.
    var anno: String? = nil
    var vistoIl: String? = nil

    var id: String {
        switch source {
        case .series(let tvdbId): return "s:\(tvdbId ?? titolo)"
        case .movie(let uuid):    return "m:\(uuid ?? titolo)"
        }
    }

    /// La risoluzione a mano esiste solo per le serie con un id TVDB usabile.
    var isResolvable: Bool {
        guard !escluso else { return false }
        if case .series(let tvdbId) = source,
           let tvdbId, let numero = Int(tvdbId), numero > 0 { return true }
        return false
    }

    var isMovie: Bool {
        if case .movie = source { return true }
        return false
    }
}

extension ImportReport {
    /// L'inbox derivato dal report: serie non riconosciute (eventi), stati per-serie rimasti
    /// fuori (fusi con la serie se già presente), film non risolti. È la lista della pagina
    /// "Titoli da verificare" e il conteggio del banner.
    var reviewItems: [ImportReviewItem] {
        leftOutItems.filter { !$0.escluso }
    }

    /// Tutto ciò che è rimasto fuori dalla libreria, **esclusioni comprese**. È la lista della
    /// pagina di report: un titolo che hai escluso tu non è più lavoro da fare, ma deve restare
    /// visibile — sparire senza traccia è il modo migliore per non fidarsi più di un import.
    var leftOutItems: [ImportReviewItem] {
        var items: [ImportReviewItem] = []
        var serieViste = Set<String>()

        for row in nonRiconosciutiElenco {
            let item = ImportReviewItem(source: .series(tvdbSeriesId: row.tvdbSeriesId),
                                        titolo: row.titolo,
                                        episodi: row.episodi,
                                        motivo: row.motivo,
                                        statoRichiesto: nil,
                                        escluso: row.escluso)
            serieViste.insert(item.id)
            items.append(item)
        }

        for row in statiNonRisoltiElenco {
            let item = ImportReviewItem(source: .series(tvdbSeriesId: row.tvdbSeriesId),
                                        titolo: row.titolo,
                                        episodi: 0,
                                        motivo: row.motivo,
                                        statoRichiesto: row.stato,
                                        escluso: row.escluso)
            // La stessa serie può avere sia episodi sia uno stato irrisolti: una card sola.
            guard serieViste.insert(item.id).inserted else { continue }
            items.append(item)
        }

        for row in filmNonRisoltiElenco {
            items.append(ImportReviewItem(source: .movie(tvtimeMovieUuid: row.tvtimeMovieUuid),
                                          titolo: row.titolo,
                                          episodi: 0,
                                          motivo: row.motivo,
                                          statoRichiesto: row.tipo,
                                          escluso: row.escluso,
                                          anno: row.anno,
                                          vistoIl: row.vistoIl))
        }

        return items
    }
}

// MARK: - La dipendenza, isolata (modello UsernameBackend)

/// Una delle associazioni raccolte prima di riaprire l'import. Il batch intero viene inviato
/// insieme: scegliere un risultato TMDB nella UI non deve mai avviare lavoro sul server.
struct ImportManualResolution: Equatable {
    let tvdbSeriesId: String
    let tmdbShowId: Int
}

@MainActor
protocol ImportBackend {
    func uploadZip(_ data: Data) async throws -> String
    func createJob(storagePath: String) async throws -> ImportStartOutcome
    func retryJob(id: String) async throws -> ImportStartOutcome
    func latestJob() async throws -> ImportJobSnapshot?
    func job(id: String) async throws -> ImportJobSnapshot?
    func report(jobId: String) async throws -> ImportReport
    /// §7.4: tutte le identità dichiarate dall'utente riaprono UN solo giro di risoluzione.
    func manualResolve(jobId: String, resolutions: [ImportManualResolution]) async throws
    /// Redesign 2.0: i titoli che l'utente ha scelto di lasciar perdere escono dall'inbox.
    func excludeUnresolved(jobId: String, seriesIds: [String], movieUuids: [String],
                           seriesTitles: [String]) async throws
}

extension ImportBackend {
    /// Default vuoto: i backend di test che non esercitano l'esclusione non devono cambiare.
    func excludeUnresolved(jobId: String, seriesIds: [String], movieUuids: [String],
                           seriesTitles: [String]) async throws {}
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
    func manualResolve(jobId: String, resolutions: [ImportManualResolution]) async throws {
        try await SupabaseService.shared.manualResolveImport(jobId: jobId, resolutions: resolutions)
    }
    func excludeUnresolved(jobId: String, seriesIds: [String], movieUuids: [String],
                           seriesTitles: [String]) async throws {
        try await SupabaseService.shared.excludeImportUnresolved(
            jobId: jobId, seriesIds: seriesIds, movieUuids: movieUuids,
            seriesTitles: seriesTitles)
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

        var isDone: Bool { if case .done = self { return true }; return false }

        /// Il nome della fase per l'evento import_failed.
        var analyticsStageName: String {
            switch self {
            case .sources: return "sources"
            case .uploading: return "uploading"
            case .running(_, let phase): return phase
            case .done: return "done"
            case .failed: return "failed"
            }
        }
    }

    @Published private(set) var state: FlowState = .sources {
        didSet { trackImportTransition(from: oldValue, to: state) }
    }

    /// Analytics sulle transizioni di stato, in un punto solo: partenza (upload), esito
    /// (report) e fallimento, qualunque ramo le abbia prodotte. `uploading → uploading` e i
    /// re-poll di `running` non emettono niente.
    private func trackImportTransition(from oldValue: FlowState, to newValue: FlowState) {
        switch (oldValue, newValue) {
        case (.sources, .uploading):
            AnalyticsService.shared.track(.importStarted(source: "tvtime_zip"))
        case (_, .done(let report)):
            guard !oldValue.isDone else { return }
            AnalyticsService.shared.track(.importCompleted(
                itemsImported: report.episodiImportati,
                itemsFailed: report.nonRiconosciutiEpisodi))
        case (_, .failed(let messageKey, _, _)):
            if case .failed = oldValue { return }
            AnalyticsService.shared.track(.importFailed(
                errorType: messageKey, stage: oldValue.analyticsStageName))
        default:
            break
        }
    }

    /// Il progresso reale (contatori delle fasi) dell'ultimo giro di polling. Vive accanto a
    /// `state` e non dentro: lo stato è il contratto storico (e dei test), il progresso è
    /// una lettura in più che la card e il banner mostrano quando c'è.
    @Published private(set) var progress: ImportProgress?

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

    /// All'apertura: l'import in corso (o l'ultimo concluso/fallito) vive sul server e va
    /// ritrovato. Un errore di rete qui lascia la lista delle sorgenti: da lì ogni strada è
    /// ancora percorribile, e un doppio avvio muore comunque su `already_running`.
    ///
    /// Redesign 2.0: anche un job `done` si riprende — è l'inbox "Titoli da verificare",
    /// che prima diventava irraggiungibile per sempre alla chiusura del report. La ripresa
    /// NON rinotifica il sync (`notify: false`): i dati di quel job sono già nello specchio
    /// locale, e un pull a ogni apertura sarebbe rumore.
    func loadExisting() async {
        guard case .sources = state else { return }
        guard let job = try? await backend.latestJob() else { return }
        progress = job.progress
        if job.isOpen {
            startPolling(jobId: job.id, phase: job.phase)
        } else if job.status == "failed" {
            state = .failed(messageKey: "import.error.failed", detail: job.error,
                            retryJobId: job.id)
        } else if job.phase == "done" || job.status == "done" {
            await showReport(jobId: job.id, notify: false)
        }
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
        } catch SupabaseError.sessionExpired {
            // La sessione è morta sotto una cache che diceva "loggato": all'utente serve
            // la frase giusta ("accedi di nuovo"), non la verità tecnica della RLS.
            state = .failed(messageKey: "import.error.sessionExpired",
                            detail: nil, retryJobId: nil)
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
            progress = job.progress
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

    private func showReport(jobId: String, notify: Bool = true) async {
        do {
            state = .done(try await backend.report(jobId: jobId))
            doneJobId = jobId
            // Il job è 'done': tutto ciò che l'import ha scritto sta già su Supabase, ma lo
            // specchio locale no. Chi osserva (AppState) fa partire il pull ADESSO — senza,
            // gli item comparivano solo al prossimo evento di rete, minuti dopo, con la
            // faccia di un import fallito. Notifica e non chiamata diretta: il ViewModel
            // resta testabile senza trascinarsi dietro il SyncEngine.
            //
            // `notify: false` è la RIPRESA di un job già concluso (loadExisting): quei dati
            // sono già stati tirati giù a suo tempo, rinotificare farebbe un pull a ogni
            // apertura dell'app.
            if notify {
                NotificationCenter.default.post(name: .importJobCompleted, object: nil)
            }
        } catch {
            // Il lavoro è fatto ma il report non si legge: dirlo, con la ripresa che
            // ricarica il report e non certo l'import.
            state = .failed(messageKey: "import.error.reportFailed",
                            detail: error.localizedDescription, retryJobId: jobId)
        }
    }

    /// Rilegge il report del job concluso a schermo — dopo un'esclusione, o al tap della
    /// push quando il report a schermo può essere invecchiato.
    func refreshReport() async {
        guard case .done = state, let jobId = doneJobId else { return }
        await showReport(jobId: jobId, notify: false)
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

    /// Tutte le associazioni vengono convalidate e inviate insieme. Il server ritenta gli
    /// episodi per i loro ID TVDB esatti e riapre il job una volta sola; qui si torna a
    /// guardarlo. `false` = input incompleto, niente da riprendere o errore.
    func resolveManually(_ resolutions: [ImportManualResolution]) async -> Bool {
        guard case .done = state, let jobId = doneJobId else { return false }
        guard !resolutions.isEmpty else { return false }
        var seriesIds = Set<Int>()
        for resolution in resolutions {
            guard let tvdbId = Int(resolution.tvdbSeriesId), tvdbId > 0,
                  resolution.tmdbShowId > 0,
                  seriesIds.insert(tvdbId).inserted else { return false }
        }
        manualResolveError = nil
        do {
            try await backend.manualResolve(jobId: jobId, resolutions: resolutions)
            startPolling(jobId: jobId, phase: "resolving")
            return true
        } catch {
            manualResolveError = error.localizedDescription
            return false
        }
    }

    /// Redesign 2.0: escludere un titolo dall'inbox. Il server marca le righe come scelte
    /// dell'utente ('escluso: utente') e il report smette di contarle; qui si rilegge il
    /// report perché card e banner calino subito.
    func excludeItems(_ items: [ImportReviewItem]) async -> Bool {
        guard case .done = state, let jobId = doneJobId, !items.isEmpty else { return false }
        var seriesIds: [String] = []
        var seriesTitles: [String] = []
        var movieUuids: [String] = []
        for item in items {
            switch item.source {
            case .series(let tvdbId):
                if let tvdbId, !tvdbId.isEmpty { seriesIds.append(tvdbId) }
                else { seriesTitles.append(item.titolo) }
            case .movie(let uuid):
                if let uuid, !uuid.isEmpty { movieUuids.append(uuid) }
            }
        }
        guard !(seriesIds.isEmpty && seriesTitles.isEmpty && movieUuids.isEmpty) else {
            return false
        }
        manualResolveError = nil
        do {
            try await backend.excludeUnresolved(jobId: jobId, seriesIds: seriesIds,
                                                movieUuids: movieUuids,
                                                seriesTitles: seriesTitles)
            await refreshReport()
            return true
        } catch {
            manualResolveError = error.localizedDescription
            return false
        }
    }
}

extension Notification.Name {
    /// L'import è arrivato al report: i dati stanno sul server, lo specchio locale ancora no.
    static let importJobCompleted = Notification.Name("ImportViewModel.importJobCompleted")
}
