import Foundation

/// SPEC v3 §9.2 — le due azioni della schermata Tracking: "visto" e "più avanti".
///
/// **Perché esiste una classe invece di due chiamate sparse nelle View.** `apply_mutations`
/// confronta `rec->>'user_id'` con `auth.uid()` e, se manca o non combacia, scrive
/// `user_id_mismatch` in `sync_rejected_mutations` **e prosegue**: nessun errore arriva al
/// client, l'evento sparisce e l'utente vede solo una serie che non avanza.
/// `normalizedMutationRecord` riempie `id` ma non `user_id`. Quindi il posto in cui `user_id`
/// viene aggiunto deve essere uno solo, e deve essere impossibile dimenticarlo: qui.
/// La parte di server che serve alla fusione ListsView-Tracking: catalogo, espansione "vista
/// tutta", e il suo contraltare. Protocollo perché i test possano sostituire la rete.
protocol TrackingSeenBackend {
    func warmCatalog(showIds: [Int]) async throws
    func expandSeenShowsToWatchEvents(_ shows: [[String: Any]]) async throws -> LegacyExpansionOutcome
    func unseeTVShow(showId: Int) async throws -> Int
}

extension SupabaseService: TrackingSeenBackend {}

@MainActor
final class TrackingActions {
    static let shared = TrackingActions()

    private let syncEngine: any SyncEngineProtocol
    private let currentUserId: @MainActor () -> String?
    private let seenBackend: any TrackingSeenBackend

    init(
        syncEngine: any SyncEngineProtocol = SyncEngine.shared,
        currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id },
        seenBackend: any TrackingSeenBackend = SupabaseService.shared
    ) {
        self.syncEngine = syncEngine
        self.currentUserId = currentUserId
        self.seenBackend = seenBackend
    }

    enum ActionError: LocalizedError, Equatable {
        case notAuthenticated
        case noNextEpisode
        case showNotInCatalog

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "tracking.error.notAuthenticated".localized
            case .noNextEpisode: return "tracking.error.noNextEpisode".localized
            case .showNotInCatalog: return "tracking.error.showNotInCatalog".localized
            }
        }
    }

    /// Marca visto il prossimo episodio della serie.
    ///
    /// Non prende stagione ed episodio da chi chiama: li prende dalla riga, che viene dal server.
    /// Se li passasse la UI, il numero potrebbe essere quello di una schermata disegnata dieci
    /// minuti fa — e §1.1 esiste per non avere due opinioni su quale sia il prossimo episodio.
    func markNextWatched(_ row: TrackingRow) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }
        guard let season = row.nextSeason, let episode = row.nextEpisode else {
            throw ActionError.noNextEpisode
        }

        let id = UUID().uuidString
        let payload: [String: Any] = [
            "id": id,
            // Obbligatorio. Vedi il commento in testa: senza, l'evento viene scartato in silenzio.
            "user_id": userId,
            "media_type": "tv",
            "tmdb_show_id": row.showId,
            "season_number": season,
            "episode_number": episode,
            "watched_at": ISO8601DateFormatter().string(from: Date()),
            "watched_at_precision": "exact",
            // §1.3: la specialita' viene dalla stagione, mai da un flag deciso altrove.
            "is_special": season == 0,
            "source": "manual",
            // `dedup_key` resta assente di proposito: §3.2 dice che il rewatch manuale e'
            // intenzionalmente ripetibile, e una chiave lo renderebbe impossibile.
        ]

        try await syncEngine.queueOperation(
            table: "watch_events",
            operationType: "INSERT",
            recordId: id,
            payload: payload,
            dependsOn: nil
        )

        // Il ponte verso la lista episodi: SeasonDetailView legge EpisodeSeenManager per i
        // tap fatti lì dentro, e senza questa riga un "visto" dalle card non vi compariva
        // finché il pull non riportava l'evento nello specchio. `markEpisodeSeen` esisteva
        // per questo (dice il suo commento) ma nessuno lo chiamava.
        EpisodeSeenManager.shared.markEpisodeSeen(
            showId: row.showId, seasonNumber: season, episodeNumber: episode)

        // Senza questo il tap non produce **niente di visibile**: l'evento parte, il trigger
        // ricalcola `tv_show_state` sul server, e la schermata continua a leggere lo specchio
        // locale `tv_tracking`, che solo un pull aggiorna. Il progresso lo decide il server
        // (§1.1) — quindi l'unico modo di sapere qual è il prossimo episodio è chiederglielo.
        await syncEngine.pullTrackingState()
    }

    /// "Più avanti": sposta la serie nel bucket `for_later` (§3.4).
    ///
    /// `user_status` è l'unica colonna di `tv_show_state` che il client può scrivere — il resto è
    /// derivato e il server è autorevole (§4, strategia `serverWins`). Un client che provasse a
    /// mandare i contatori se li vedrebbe ignorare, cosa già verificata in produzione.
    func snooze(_ row: TrackingRow) async throws {
        try await setStatus(row, to: "for_later")
    }

    func setStatus(_ row: TrackingRow, to status: String) async throws {
        try await setStatus(showId: row.showId, to: status)
    }

    func setStatus(showId: Int, to status: String) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }

        let payload: [String: Any] = [
            "user_id": userId,
            "tmdb_show_id": showId,
            "user_status": status,
        ]

        try await syncEngine.queueOperation(
            table: "tv_show_state",
            operationType: "UPSERT",
            // La chiave e' composta e non c'e' una colonna `id`: si usa la coppia, che e' cio' che
            // identifica la riga davvero.
            recordId: "\(userId):\(showId)",
            payload: payload,
            dependsOn: nil
        )

        // Come sopra: il bucket lo calcola `tv_tracking_bucket` lato server, e finché non si
        // ritira la vista la serie resta dov'era.
        await syncEngine.pullTrackingState()
    }

    // MARK: - Fusione ListsView-Tracking (2026-08-02)

    /// "Aggiungi alla watchlist" per una serie: la riga di `tv_show_state` nasce `active` con
    /// zero episodi, cioè "Da iniziare" — la scelta dell'utente, stessa semantica dell'import
    /// per le serie seguite mai iniziate.
    func addToWatchlist(showId: Int) async throws {
        try await setStatus(showId: showId, to: "active")
    }

    /// Togliere dalla watchlist non è cancellare la riga (derivata, il server è autorevole):
    /// è `dropped`, che la fa sparire sia dalle liste sia dal Tracking senza perdere lo storico.
    func removeFromWatchlist(showId: Int) async throws {
        try await setStatus(showId: showId, to: "dropped")
    }

    /// "Vista tutta": l'espansione server scrive un evento per ogni episodio già uscito che il
    /// catalogo conosce (§1.4 — il client sa *che* è vista, non *quali* episodi la compongono).
    /// Prima si riscalda il catalogo: per una serie mai vista da nessuno non c'è ancora.
    func markSeen(showId: Int) async throws {
        guard currentUserId() != nil else { throw ActionError.notAuthenticated }

        try await seenBackend.warmCatalog(showIds: [showId])
        let outcome = try await seenBackend.expandSeenShowsToWatchEvents([[
            "tmdb_show_id": showId,
            "watched_at": ISO8601DateFormatter().string(from: Date()),
        ]])
        // Zero eventi scritti per mancanza di catalogo NON è un successo: dirlo, invece di
        // lasciare una serie "vista" che resta identica a prima (il fallimento muto di sempre).
        if outcome.showsWithoutCatalog.contains(showId) {
            throw ActionError.showNotInCatalog
        }

        await syncEngine.pullTrackingState()
    }

    /// Il contraltare: lapide su tutti gli eventi della serie + `dropped`, in un'unica RPC —
    /// centinaia di DELETE una a una dall'outbox non sono una strada, e senza il `dropped` il
    /// ricalcolo farebbe ricomparire la serie come "Da iniziare".
    func unsee(showId: Int) async throws {
        guard currentUserId() != nil else { throw ActionError.notAuthenticated }
        _ = try await seenBackend.unseeTVShow(showId: showId)
        await syncEngine.pullTrackingState()
    }
}
