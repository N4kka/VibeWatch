import Foundation

/// SPEC v3 §9.2 — le due azioni della schermata Tracking: "visto" e "più avanti".
///
/// **Perché esiste una classe invece di due chiamate sparse nelle View.** `apply_mutations`
/// confronta `rec->>'user_id'` con `auth.uid()` e, se manca o non combacia, scrive
/// `user_id_mismatch` in `sync_rejected_mutations` **e prosegue**: nessun errore arriva al
/// client, l'evento sparisce e l'utente vede solo una serie che non avanza.
/// `normalizedMutationRecord` riempie `id` ma non `user_id`. Quindi il posto in cui `user_id`
/// viene aggiunto deve essere uno solo, e deve essere impossibile dimenticarlo: qui.
@MainActor
final class TrackingActions {
    static let shared = TrackingActions()

    private let syncEngine: any SyncEngineProtocol
    private let currentUserId: @MainActor () -> String?

    init(
        syncEngine: any SyncEngineProtocol = SyncEngine.shared,
        currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id }
    ) {
        self.syncEngine = syncEngine
        self.currentUserId = currentUserId
    }

    enum ActionError: LocalizedError {
        case notAuthenticated
        case noNextEpisode

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "tracking.error.notAuthenticated".localized
            case .noNextEpisode: return "tracking.error.noNextEpisode".localized
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
        guard let userId = currentUserId() else { throw ActionError.notAuthenticated }

        let payload: [String: Any] = [
            "user_id": userId,
            "tmdb_show_id": row.showId,
            "user_status": status,
        ]

        try await syncEngine.queueOperation(
            table: "tv_show_state",
            operationType: "UPSERT",
            // La chiave e' composta e non c'e' una colonna `id`: si usa la coppia, che e' cio' che
            // identifica la riga davvero.
            recordId: "\(userId):\(row.showId)",
            payload: payload,
            dependsOn: nil
        )

        // Come sopra: il bucket lo calcola `tv_tracking_bucket` lato server, e finché non si
        // ritira la vista la serie resta dov'era.
        await syncEngine.pullTrackingState()
    }
}
