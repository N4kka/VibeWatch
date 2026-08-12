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

/// Lo specchio locale di `watch_events`, ridotto a ciò che serve alle azioni episodio-livello
/// della lista episodi (SeasonDetailView). Protocollo per gli stessi motivi di
/// `TrackingSeenBackend`: nei test lo specchio è un dizionario, non il database dell'app.
protocol WatchEventLocalMirror {
    func insert(_ record: [String: Any]) async
    func activeEventIds(userId: String, showId: Int, season: Int, episode: Int) async -> [String]
    func tombstone(ids: [String]) async
}

struct SQLiteWatchEventMirror: WatchEventLocalMirror {
    func insert(_ record: [String: Any]) async {
        let id = record["id"] as? String ?? ""
        let userId = record["user_id"] as? String ?? ""
        let showId = record["tmdb_show_id"] as? Int ?? 0
        let season = record["season_number"] as? Int ?? 0
        let episode = record["episode_number"] as? Int ?? 0
        let watchedAt = record["watched_at"] as? String ?? ""
        let precision = record["watched_at_precision"] as? String ?? "exact"
        let isSpecial = (record["is_special"] as? Bool) == true ? 1 : 0
        let source = record["source"] as? String ?? "manual"
        let parameters: [Any] = [
            id, userId, showId, season, episode, watchedAt, precision, isSpecial, source,
        ]
        do {
            try await SQLiteService.shared.executeWrite(
                """
                INSERT OR IGNORE INTO watch_events (
                    id, user_id, media_type, tmdb_show_id, season_number, episode_number,
                    watched_at, watched_at_precision, is_special, source
                ) VALUES (?, ?, 'tv', ?, ?, ?, ?, ?, ?, ?)
                """,
                parameters: parameters
            )
        } catch {
            // Lo specchio si riallinea comunque al prossimo pull completo: si logga e basta.
            Logger.warning("[Tracking] write-through specchio fallito: \(error.localizedDescription)")
        }
    }

    func activeEventIds(userId: String, showId: Int, season: Int, episode: Int) async -> [String] {
        let rows = (try? await SQLiteService.shared.queryRaw(
            """
            SELECT id FROM watch_events
            WHERE user_id = ? AND tmdb_show_id = ? AND season_number = ? AND episode_number = ?
              AND media_type = 'tv' AND deleted_at IS NULL
            """,
            parameters: [userId, showId, season, episode]
        )) ?? []
        return rows.compactMap { $0["id"] as? String }
    }

    func tombstone(ids: [String]) async {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try? await SQLiteService.shared.executeWrite(
            "UPDATE watch_events SET deleted_at = datetime('now') WHERE id IN (\(placeholders))",
            parameters: ids
        )
    }
}

@MainActor
final class TrackingActions {
    static let shared = TrackingActions()

    private let syncEngine: any SyncEngineProtocol
    private let currentUserId: @MainActor () -> String?
    private let seenBackend: any TrackingSeenBackend
    private let mirror: any WatchEventLocalMirror
    private let showHasCatalog: @MainActor (Int) async -> Bool

    init(
        syncEngine: any SyncEngineProtocol = SyncEngine.shared,
        currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id },
        seenBackend: any TrackingSeenBackend = SupabaseService.shared,
        mirror: any WatchEventLocalMirror = SQLiteWatchEventMirror(),
        showHasCatalog: @escaping @MainActor (Int) async -> Bool = {
            await TrackingActions.catalogIsKnown(showId: $0)
        }
    ) {
        self.syncEngine = syncEngine
        self.currentUserId = currentUserId
        self.seenBackend = seenBackend
        self.mirror = mirror
        self.showHasCatalog = showHasCatalog
    }

    /// Il server conosce gli episodi di questa serie?
    ///
    /// Si legge dallo specchio locale invece di chiederlo alla rete: `total_count` viene da
    /// `tmdb_episodes`, quindi vale zero esattamente quando il catalogo non c'è. Una serie che
    /// non compare affatto nello specchio non è mai stata tracciata, e il catalogo per lei può
    /// non essere mai stato risolto da nessuno (§1.5).
    private static func catalogIsKnown(showId: Int) async -> Bool {
        guard let userId = SupabaseService.shared.currentUser?.id else { return false }
        let rows = (try? await SQLiteService.shared.queryRaw(
            "SELECT total_count FROM tv_tracking WHERE user_id = ? AND tmdb_show_id = ? LIMIT 1",
            parameters: [userId, showId]
        )) ?? []
        guard let raw = rows.first?["total_count"] else { return false }
        if let value = raw as? Int { return value > 0 }
        if let value = raw as? Int64 { return value > 0 }
        if let value = raw as? Double { return value > 0 }
        if let value = raw as? String { return (Int(value) ?? 0) > 0 }
        return false
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

        try await queueWatchEvent(userId: userId, showId: row.showId, season: season, episode: episode)

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
        // `flush`: prima che l'evento sia arrivato, ritirare lo stato riscrive la card com'era.
        await syncEngine.flushAndPullTrackingState()
        Self.announceTrackingChanged()
    }

    // MARK: - Azioni episodio-livello (lista episodi di SeasonDetailView)

    /// Un "visto" tappato sulla lista episodi. Stessa mutazione della card Tracking — è ciò che
    /// fa avanzare le card di Scopri e del Tracking, che prima questo tap non toccava affatto —
    /// più il write-through nello specchio locale, così lo smarcamento ritrova l'id anche prima
    /// del pull completo. Batch perché "hai visto anche i precedenti?" ne marca N in un colpo.
    func markEpisodesWatched(showId: Int, episodes: [(season: Int, episode: Int)]) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }
        guard !episodes.isEmpty else { return }

        // PRIMA il catalogo, come in `addToWatchlist`, e per la stessa ragione: il ricalcolo
        // server deriva prossimo episodio e contatori da `tmdb_episodes`, e per una serie che
        // nessuno ha mai tracciato quel catalogo non esiste ancora. Senza, marcare un episodio
        // dalla lista di SeasonView produceva una riga con zero episodi totali — nessun prossimo
        // episodio, bucket `up_to_date`, quindi né in "Continua a guardare" né in cima al
        // Tracking: "l'ho segnato e non si è mosso niente". Best-effort: se il warm fallisce
        // (offline) l'evento si scrive lo stesso e il self-heal del Tracking ripara dopo.
        let catalogoNoto = await showHasCatalog(showId)
        if !catalogoNoto {
            try? await seenBackend.warmCatalog(showIds: [showId])
        }

        for ep in episodes {
            try await queueWatchEvent(userId: userId, showId: showId, season: ep.season, episode: ep.episode)
            EpisodeSeenManager.shared.markEpisodeSeen(
                showId: showId, seasonNumber: ep.season, episodeNumber: ep.episode)
        }

        await syncEngine.flushAndPullTrackingState()
        Self.announceTrackingChanged()
    }

    /// Lo smarcamento di un episodio dalla lista: lapide sugli eventi noti allo specchio locale
    /// (DELETE remota per id) + rimozione del tap locale. `allEpisodeNumbersInSeason` serve a
    /// EpisodeSeenManager per espandere l'eventuale flag "serie vista" in chiavi per-episodio.
    func unmarkEpisodesWatched(
        showId: Int,
        episodes: [(season: Int, episode: Int)],
        allEpisodeNumbersInSeason: [Int]
    ) async throws {
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }
        guard !episodes.isEmpty else { return }

        for ep in episodes {
            let ids = await mirror.activeEventIds(
                userId: userId, showId: showId, season: ep.season, episode: ep.episode)
            for id in ids {
                try await syncEngine.queueOperation(
                    table: "watch_events",
                    operationType: "DELETE",
                    recordId: id,
                    payload: ["id": id, "user_id": userId],
                    dependsOn: nil
                )
            }
            await mirror.tombstone(ids: ids)
            EpisodeSeenManager.shared.unmarkEpisode(
                showId: showId, seasonNumber: ep.season, episodeNumber: ep.episode,
                allEpisodeNumbersInSeason: allEpisodeNumbersInSeason)
        }

        await syncEngine.flushAndPullTrackingState()
        Self.announceTrackingChanged()
    }

    /// Le card di Scopri e del Tracking si rileggono al `syncEngineCompleted`: dopo un'azione
    /// partita da un'altra schermata (la lista episodi) non c'è nessun ViewModel da ricaricare a
    /// mano, quindi si annuncia — come fa il sync — e ognuno si riallinea da sé.
    private static func announceTrackingChanged() {
        NotificationCenter.default.post(name: .syncEngineCompleted, object: nil)
    }

    private func queueWatchEvent(userId: String, showId: Int, season: Int, episode: Int) async throws {
        let id = UUID().uuidString
        let payload: [String: Any] = [
            "id": id,
            // Obbligatorio. Vedi il commento in testa: senza, l'evento viene scartato in silenzio.
            "user_id": userId,
            "media_type": "tv",
            "tmdb_show_id": showId,
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
        await mirror.insert(payload)
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
        // ritira la vista la serie resta dov'era — dopo che la mutazione è arrivata, non prima.
        await syncEngine.flushAndPullTrackingState()
    }

    // MARK: - Fusione ListsView-Tracking (2026-08-02)

    /// "Aggiungi alla watchlist" per una serie: la riga di `tv_show_state` nasce `active` con
    /// zero episodi, cioè "Da iniziare" — la scelta dell'utente, stessa semantica dell'import
    /// per le serie seguite mai iniziate.
    ///
    /// PRIMA il catalogo: il ricalcolo server deriva prossimo episodio e contatori da
    /// `tmdb_episodes`, e per una serie mai vista da nessuno il catalogo non c'è ancora — la
    /// riga nasceva vuota e la card "Da iniziare" compariva senza copertina e senza S1E1.
    /// Best-effort: se il warm fallisce (offline) lo stato si scrive comunque, e il self-heal
    /// del Tracking (`repairMissingCatalog`) ripara alla prossima apertura.
    func addToWatchlist(showId: Int) async throws {
        try? await seenBackend.warmCatalog(showIds: [showId])
        try await setStatus(showId: showId, to: "active")
    }

    /// Ripara le righe di tracking nate senza catalogo (una serie in "Da iniziare" senza poster
    /// né prossimo episodio): riscalda il catalogo, poi ri-upserta lo `user_status` corrente —
    /// è il modo con cui un client fa ripartire `recompute_tv_show_state`, che `catalog-resolve`
    /// da solo non tocca — e infine ritira lo stato ricalcolato.
    func repairMissingCatalog(rows: [(showId: Int, userStatus: String)]) async {
        guard let userId = currentUserId(), !rows.isEmpty else { return }

        do {
            try await seenBackend.warmCatalog(showIds: rows.map(\.showId))
        } catch {
            // Senza catalogo il ricalcolo produrrebbe gli stessi zeri: inutile accodare
            // mutazioni. Si riproverà alla prossima apertura della schermata.
            Logger.warning("[Tracking] warm del catalogo fallito: \(error.localizedDescription)")
            return
        }

        for row in rows {
            try? await syncEngine.queueOperation(
                table: "tv_show_state",
                operationType: "UPSERT",
                recordId: "\(userId):\(row.showId)",
                payload: [
                    "user_id": userId,
                    "tmdb_show_id": row.showId,
                    "user_status": row.userStatus,
                ],
                dependsOn: nil
            )
        }

        await syncEngine.flushAndPullTrackingState()
        Self.announceTrackingChanged()
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
