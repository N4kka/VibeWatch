import Foundation

/// SPEC v3 §12 blocco 7 — porta lo storico di chi usa gia' VibeWatch dentro `watch_events`.
///
/// **Perche' esiste.** Il blocco 6 ha progettato l'import per chi arriva da TV Time. Chi usa
/// VibeWatch da prima non passa da li', e la schermata Tracking nuova — che legge `watch_events`
/// via `v_tv_tracking` — per lui e' **vuota**. Non e' un guasto: il pull funziona, e' il server
/// che per quell'utente non ha niente. Lo storico vive in `EpisodeSeenManager` (UserDefaults) e
/// nelle liste, e nessuno lo ha mai copiato di la'.
///
/// **Cosa fa, nell'ordine, e perche' quell'ordine.**
/// 1. **riscalda il catalogo** delle serie coinvolte (`catalog-resolve` con `show_ids`). Va prima
///    di tutto: senza `tmdb_episodes` una serie "vista per intero" non e' espandibile, e senza
///    `tmdb_shows` la card non ha nome ne' poster;
/// 2. **scrive gli episodi singoli** via `apply_mutations`, in lotti;
/// 3. **espande le serie viste per intero** con `expand_seen_shows_to_watch_events`, che sta
///    server-side perche' li' c'e' il catalogo (§1.4);
/// 4. **ritira** lo stato ricalcolato, cosi' la schermata si riempie senza aspettare il sync dopo.
///
/// **Perche' non passa dall'outbox.** `SyncEngine.queueOperation` fa una chiamata HTTP per
/// operazione e ne processa 50 per sync: qualche centinaio di episodi vorrebbe dire altrettanti
/// round-trip spalmati su decine di avvii. `apply_mutations` accetta un lotto — e' cosi' che lo usa
/// l'import (§7.2 fase 4) — e questa e' una migrazione una tantum, non una scrittura dell'utente.
/// La durabilita' che l'outbox darebbe la da' la `dedup_key`: se si interrompe, si rigioca.
///
/// **Idempotente per costruzione.** Ogni evento porta `dedup_key = legacy:{show}:{s}:{e}`, e sia
/// `apply_mutations` sia l'espansione saltano cio' che c'e' gia' (criterio 2 di §13). Il flag in
/// `app_metadata` serve a non rifare il lavoro, non a garantire la correttezza.
@MainActor
final class LegacyTrackingMigration {
    static let shared = LegacyTrackingMigration()

    /// Il marcatore in `app_metadata`, come le altre migration locali.
    static let versionKey = "legacy_tracking_migration_version"
    static let attemptsKey = "legacy_tracking_migration_attempts"
    static let currentVersion = 1

    /// Dopo tot avvii ci si ferma comunque. Una serie che TMDB non conosce piu' non si risolvera'
    /// mai, e riprovare a ogni lancio per sempre sarebbe un ciclo che nessuno nota — che e' la
    /// forma di guasto che questo progetto ha gia' pagato piu' volte.
    static let maxAttempts = 3

    /// `catalog-resolve` non accetta piu' di 50 id per richiesta.
    private static let showsPerCatalogCall = 50
    /// Il lotto di `apply_mutations`. La funzione cicla in PL/pgSQL sull'array: sta comodamente
    /// dentro lo `statement_timeout = 8s` del ruolo `authenticated`, con margine.
    private static let eventsPerMutationCall = 200
    private static let showsPerExpandCall = 50

    private let backend: any LegacyTrackingMigrationBackend
    private let store: any LegacyTrackingMigrationStore
    private let pullAfterwards: @MainActor () async -> Void

    /// I default sono `nil` e non le implementazioni vere: un valore di default viene valutato nel
    /// contesto del chiamante, che non e' isolato al main actor, e costruire li' un tipo
    /// `@MainActor` non compila.
    init(
        backend: (any LegacyTrackingMigrationBackend)? = nil,
        store: (any LegacyTrackingMigrationStore)? = nil,
        pullAfterwards: (@MainActor () async -> Void)? = nil
    ) {
        self.backend = backend ?? SupabaseLegacyTrackingBackend()
        self.store = store ?? SQLiteLegacyTrackingStore()
        self.pullAfterwards = pullAfterwards ?? { await SyncEngine.shared.pullFromRemote() }
    }

    struct Report: Equatable {
        var episodesQueued = 0
        var wholeShowsExpanded = 0
        var eventsFromExpansion = 0
        var showsWithoutCatalog: [Int] = []
        var completed = false
    }

    /// Esegue la migrazione se non e' gia' stata fatta. Sicura da chiamare a ogni avvio.
    @discardableResult
    func runIfNeeded(userId: String?) async -> Report? {
        guard await store.version() < Self.currentVersion else { return nil }

        guard let userId, !userId.isEmpty else {
            // Non si segna niente: senza utente non c'e' `user_id` da mettere nei record, e un
            // record senza `user_id` viene scartato in silenzio da `apply_mutations`. Si riprova
            // al primo avvio autenticato.
            Logger.info("[LegacyMigration] rimandata: nessun utente autenticato")
            return nil
        }

        let attempts = await store.attempts()
        guard attempts < Self.maxAttempts else {
            Logger.warning(
                "[LegacyMigration] \(attempts) tentativi senza chiudere: si smette e si segna fatta")
            store.setVersion(Self.currentVersion)
            return nil
        }
        store.setAttempts(attempts + 1)

        let plan = store.readPlan()
        guard !plan.isEmpty else {
            Logger.info("[LegacyMigration] niente da migrare")
            store.setVersion(Self.currentVersion)
            return Report(completed: true)
        }

        Logger.info(
            "[LegacyMigration] \(plan.episodes.count) episodi, \(plan.wholeShows.count) serie viste "
            + "per intero, \(plan.showIds.count) serie da riscaldare — tentativo \(attempts + 1)")

        var report = Report()
        // Le date di aggiunta alle liste: l'unico timestamp reale che questo storico possiede.
        let watchedAt = await store.watchedAtByShow()
        let now = Date()

        // 1. Catalogo. Best effort: una serie che non si riscalda non blocca la migrazione degli
        //    episodi, che sono scrivibili comunque — `watch_events.tmdb_show_id` non ha una FK sul
        //    catalogo apposta. Peggiora la card, non perde il dato.
        for lotto in plan.showIds.chunked(into: Self.showsPerCatalogCall) {
            do {
                try await backend.warmCatalog(showIds: lotto)
            } catch {
                Logger.warning("[LegacyMigration] riscaldamento catalogo fallito su un lotto: \(error)")
            }
        }

        // 2. Episodi singoli.
        var episodiScritti = 0
        for lotto in plan.episodes.chunked(into: Self.eventsPerMutationCall) {
            let mutations = lotto.map { episodio -> [String: Any] in
                let record = LegacyTrackingPlan.record(
                    for: episodio,
                    userId: userId,
                    watchedAt: watchedAt[episodio.showId] ?? now
                )
                return [
                    "op": "INSERT",
                    "table": "watch_events",
                    "id": record["id"] as? String ?? UUID().uuidString,
                    "record": record,
                ]
            }
            do {
                try await backend.writeEvents(mutations)
                episodiScritti += lotto.count
            } catch {
                // Si dichiara e si esce senza segnare fatta: il prossimo avvio rigioca, e la
                // dedup_key fa si' che i lotti gia' passati non producano duplicati. Un `try?`
                // qui darebbe una migrazione "riuscita" a meta', che e' peggio di una fallita.
                Logger.error("[LegacyMigration] scrittura eventi fallita: \(error.localizedDescription)")
                report.episodesQueued = episodiScritti
                return report
            }
        }
        report.episodesQueued = episodiScritti

        // 3. Serie viste per intero.
        var senzaCatalogo: [Int] = []
        for lotto in plan.wholeShows.chunked(into: Self.showsPerExpandCall) {
            let shows = lotto.map { showId -> [String: Any] in
                [
                    "tmdb_show_id": showId,
                    "watched_at": ISO8601DateFormatter()
                        .string(from: watchedAt[showId] ?? now),
                ]
            }
            do {
                let esito = try await backend.expandSeenShows(shows)
                report.eventsFromExpansion += esito.eventsWritten
                senzaCatalogo.append(contentsOf: esito.showsWithoutCatalog)
            } catch {
                Logger.error("[LegacyMigration] espansione fallita: \(error.localizedDescription)")
                return report
            }
        }
        report.wholeShowsExpanded = plan.wholeShows.count - senzaCatalogo.count
        report.showsWithoutCatalog = senzaCatalogo

        if senzaCatalogo.isEmpty {
            store.setVersion(Self.currentVersion)
            report.completed = true
        } else {
            // Non si chiude: il riscaldamento del catalogo puo' essere stato tagliato dalla
            // deadline o dal budget di `catalog-resolve`, e al prossimo avvio quelle serie
            // potrebbero esserci. Dopo `maxAttempts` si chiude comunque.
            Logger.warning(
                "[LegacyMigration] \(senzaCatalogo.count) serie senza catalogo, si riprova al "
                + "prossimo avvio: \(senzaCatalogo.prefix(10))")
        }

        Logger.info(
            "[LegacyMigration] \(report.episodesQueued) episodi + \(report.eventsFromExpansion) "
            + "da espansione, completata=\(report.completed)")

        // 4. Lo stato l'ha ricalcolato il server: si ritira, altrimenti la schermata resta vuota
        //    fino al sync successivo — cioe' l'utente vede ancora il difetto che questo codice
        //    esiste per togliere.
        await pullAfterwards()

        return report
    }
}

// MARK: - Le due dipendenze, isolate per poterle sostituire nei test

struct LegacyExpansionOutcome: Equatable {
    let eventsWritten: Int
    let showsWithoutCatalog: [Int]
}

@MainActor
protocol LegacyTrackingMigrationBackend {
    /// Popola `tmdb_shows`/`tmdb_episodes` per serie gia' identificate su TMDB.
    func warmCatalog(showIds: [Int]) async throws
    /// Un lotto di mutazioni per `apply_mutations`.
    func writeEvents(_ mutations: [[String: Any]]) async throws
    /// Espande le serie viste per intero dal catalogo, server-side.
    func expandSeenShows(_ shows: [[String: Any]]) async throws -> LegacyExpansionOutcome
}

@MainActor
protocol LegacyTrackingMigrationStore {
    func version() async -> Int
    func setVersion(_ version: Int)
    func attempts() async -> Int
    func setAttempts(_ attempts: Int)
    /// Cosa c'e' da migrare, letto dalle sorgenti legacy.
    func readPlan() -> LegacyTrackingPlan
    /// La data da usare come `watched_at`, per serie. Una query sola e non una per serie: sono
    /// centinaia di serie, e la migrazione gira all'avvio.
    func watchedAtByShow() async -> [Int: Date]
}

// MARK: - Implementazioni reali

@MainActor
struct SupabaseLegacyTrackingBackend: LegacyTrackingMigrationBackend {

    func warmCatalog(showIds: [Int]) async throws {
        try await SupabaseService.shared.warmCatalog(showIds: showIds)
    }

    func writeEvents(_ mutations: [[String: Any]]) async throws {
        // Niente ripiego per riga: la dedup di questa migrazione vive nella `dedup_key`, che solo
        // `apply_mutations` conosce. Meglio fallire e rigiocare al prossimo avvio.
        try await SupabaseService.shared.applyMutations(mutations, allowClientSideFallback: false)
    }

    func expandSeenShows(_ shows: [[String: Any]]) async throws -> LegacyExpansionOutcome {
        try await SupabaseService.shared.expandSeenShowsToWatchEvents(shows)
    }
}

@MainActor
struct SQLiteLegacyTrackingStore: LegacyTrackingMigrationStore {
    private let db = SQLiteService.shared

    func version() async -> Int {
        Int(await readMetadata(LegacyTrackingMigration.versionKey) ?? "0") ?? 0
    }

    func setVersion(_ version: Int) {
        db.execute(
            "INSERT OR REPLACE INTO app_metadata (key_name, value_text) VALUES (?, ?)",
            parameters: [LegacyTrackingMigration.versionKey, String(version)]
        )
    }

    func attempts() async -> Int {
        Int(await readMetadata(LegacyTrackingMigration.attemptsKey) ?? "0") ?? 0
    }

    func setAttempts(_ attempts: Int) {
        db.execute(
            "INSERT OR REPLACE INTO app_metadata (key_name, value_text) VALUES (?, ?)",
            parameters: [LegacyTrackingMigration.attemptsKey, String(attempts)]
        )
    }

    func readPlan() -> LegacyTrackingPlan {
        LegacyTrackingPlan.build(
            seenKeys: EpisodeSeenManager.shared.seenKeys,
            seenShowIds: EpisodeSeenManager.shared.seenShowIds,
            seenListShowIds: Set(
                ListManager.shared.seenList.items
                    .filter { $0.mediaType == .tv }
                    .map(\.mediaId)
            )
        )
    }

    /// La data di aggiunta alla lista, quando esiste; `now()` altrimenti.
    ///
    /// Non e' un dettaglio estetico: `backlog_since = greatest(next.air_date, last_watched_at)`
    /// (§3.3). Con `now()` su tutto, ogni serie arretrata finirebbe in cima a "Da guardare"
    /// nello stesso istante e la sezione "Non visti da tempo" resterebbe vuota per sempre — cioe'
    /// l'ordinamento che e' il motivo per cui esiste la schermata sarebbe inutile.
    func watchedAtByShow() async -> [Int: Date] {
        let rows: [[String: Any]]
        do {
            rows = try await db.queryRaw("""
                SELECT media_id, MIN(added_at) AS added_at
                  FROM list_items
                 WHERE media_type = 'tv' AND deleted_at IS NULL AND added_at IS NOT NULL
                 GROUP BY media_id
            """)
        } catch {
            // Si dichiara: senza queste date la migrazione funziona lo stesso ma ogni serie
            // arretrata finisce in cima a "Da guardare" nello stesso istante, e sembrerebbe un
            // difetto dell'ordinamento invece che una lettura fallita.
            Logger.warning("[LegacyMigration] date di aggiunta non leggibili: \(error)")
            return [:]
        }

        var byShow: [Int: Date] = [:]
        for row in rows {
            guard let showId = row["media_id"] as? Int,
                  let date = SupabaseSyncFormatting.parseDate(row["added_at"]) else { continue }
            byShow[showId] = date
        }
        return byShow
    }

    private func readMetadata(_ key: String) async -> String? {
        let rows = try? await db.queryRaw(
            "SELECT value_text FROM app_metadata WHERE key_name = ?", parameters: [key])
        return rows?.first?["value_text"] as? String
    }
}

