import Foundation

/// SPEC v3 §12 blocco 7 — cosa va migrato dallo storico di chi usa gia' VibeWatch, e in che forma.
///
/// **Il buco che questo chiude.** La schermata Tracking legge `watch_events`. Per chi arriva da TV
/// Time la riempie l'import (§7.2); per chi usava VibeWatch da prima non la riempie nessuno, e la
/// schermata e' **vuota** — i dati non sono persi, stanno dove sono sempre stati (`UserDefaults`
/// di `EpisodeSeenManager` e le liste), semplicemente il sistema nuovo non li ha mai visti.
///
/// Questo tipo e' la parte **pura**: da tre insiemi in ingresso produce l'elenco di cio' che va
/// scritto, senza toccare rete, database o orologio. Sta separata dall'esecuzione perche' e' la
/// parte in cui si sbaglia in silenzio — una chiave malformata interpretata a caso diventa un
/// episodio visto che l'utente non ha mai visto, e nessuno se ne accorgerebbe.
struct LegacyTrackingPlan: Equatable {

    /// Un episodio che l'utente ha marcato singolarmente: la coppia c'e' gia', non va dedotta.
    struct Episode: Equatable, Hashable {
        let showId: Int
        let season: Int
        let episode: Int
    }

    /// Episodi con stagione e numero noti.
    let episodes: [Episode]

    /// Serie marcate "viste per intero" — dal flag di `EpisodeSeenManager` o dall'essere nella
    /// lista `seen`. **Non dicono quali episodi**, e per saperlo serve il catalogo: si espandono
    /// server-side (`expand_seen_shows_to_watch_events`), dove il catalogo vive (§1.4).
    let wholeShows: [Int]

    /// Tutte le serie coinvolte. E' l'elenco da riscaldare nel catalogo prima di scrivere: senza
    /// `tmdb_shows`/`tmdb_episodes` la card non ha nome ne' prossimo episodio, e le serie viste
    /// per intero non sono nemmeno espandibili.
    var showIds: [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for id in episodes.map(\.showId) + wholeShows where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

    var isEmpty: Bool { episodes.isEmpty && wholeShows.isEmpty }

    /// - Parameters:
    ///   - seenKeys: `EpisodeSeenManager.seenKeys`, nella forma `"{showId}_{season}_{episode}"`.
    ///   - seenShowIds: `EpisodeSeenManager.seenShowIds` — serie marcate viste per intero.
    ///   - seenListShowIds: le serie nella lista di tipo `seen`. `ListManager` marca gia'
    ///     `markShowSeen` quando ce le mette, ma quel flag vive in UserDefaults e un'installazione
    ///     nuova che ritira le liste dal server ha la lista e non il flag: le due sorgenti vanno
    ///     unite, non scelte.
    static func build(
        seenKeys: Set<String>,
        seenShowIds: Set<Int>,
        seenListShowIds: Set<Int>
    ) -> LegacyTrackingPlan {
        var episodes: [Episode] = []
        var visti = Set<Episode>()

        // Ordinate: l'ordine di un Set cambia a ogni esecuzione, e un piano che cambia ordine
        // rende irriproducibile qualunque diagnosi su un lotto scritto a meta'.
        for key in seenKeys.sorted() {
            guard let episode = parse(key) else { continue }
            if visti.insert(episode).inserted { episodes.append(episode) }
        }

        // Le serie viste per intero **non** tolgono di mezzo i loro episodi singoli. Sembrerebbe
        // ridondante — l'espansione li riscriverebbe — ma l'espansione conosce solo cio' che sta
        // nel catalogo, e l'oracolo documenta 41 serie su 430 in cui la numerazione dell'utente e
        // quella di TMDB non coincidono. Gli episodi singoli sono l'unica prova di quelli. La
        // `dedup_key` e' la stessa, quindi la sovrapposizione non costa niente.
        let wholeShows = seenShowIds.union(seenListShowIds).sorted()

        return LegacyTrackingPlan(episodes: episodes, wholeShows: wholeShows)
    }

    /// `"{showId}_{season}_{episode}"` -> episodio, oppure `nil`.
    ///
    /// Si rifiuta invece di indovinare. Una chiave con un pezzo in meno, o con un numero che non
    /// e' un numero, non e' un episodio "quasi giusto": scriverla come `(show, 0, 0)` produrrebbe
    /// un evento plausibile e falso, che poi conta nel progresso.
    ///
    /// `episode == 0` invece si accetta: qui la chiave l'ha scritta l'app da un episodio TMDB
    /// vero, e TMDB un episodio 0 ce l'ha. E' il caso opposto a quello dell'export TV Time, dove
    /// `episode_number = 0` significava "numerazione persa" — la stessa forma, sorgenti diverse.
    static func parse(_ key: String) -> Episode? {
        let parts = key.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let showId = Int(parts[0]), showId > 0,
              let season = Int(parts[1]), season >= 0,
              let episode = Int(parts[2]), episode >= 0
        else { return nil }
        return Episode(showId: showId, season: season, episode: episode)
    }

    /// La chiave di idempotenza, identica a quella che usa `expand_seen_shows_to_watch_events`:
    /// le due sorgenti convergono sulla stessa riga invece di produrne due (criterio 2 di §13).
    static func dedupKey(_ e: Episode) -> String {
        "legacy:\(e.showId):\(e.season):\(e.episode)"
    }

    /// Il record da mandare ad `apply_mutations`.
    ///
    /// - Parameter userId: **obbligatorio**. `apply_mutations` confronta `rec->>'user_id'` con
    ///   `auth.uid()` e, se manca, scrive `user_id_mismatch` in `sync_rejected_mutations` e
    ///   prosegue: nessun errore arriva al client, l'evento sparisce. E' lo stesso motivo per cui
    ///   `TrackingActions` esiste come classe unica.
    /// - Parameter watchedAt: non c'e' una risposta giusta — la data di visione vera non esiste in
    ///   UserDefaults. Si usa quella di aggiunta alla lista quando c'e', perche' e' l'unico
    ///   timestamp reale disponibile ed e' anche quello che rende utile `backlog_since` (§3.3):
    ///   con `now()` su tutto, ogni serie finirebbe in cima a "Da guardare" nello stesso istante.
    ///   `watched_at_precision` resta `inferred` in ogni caso (§3.2).
    static func record(for e: Episode, userId: String, watchedAt: Date) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "user_id": userId,
            "media_type": "tv",
            "tmdb_show_id": e.showId,
            "season_number": e.season,
            "episode_number": e.episode,
            "watched_at": ISO8601DateFormatter().string(from: watchedAt),
            // §3.2: mai `exact`. La data e' dedotta, e marcarla esatta significherebbe inventarla.
            "watched_at_precision": "inferred",
            // §1.3: la specialita' viene dalla stagione, mai da un flag deciso altrove.
            "is_special": e.season == 0,
            "source": "import_other",
            "external_ref": ["legacy_origin": "episode_seen_manager"],
            "dedup_key": dedupKey(e),
        ]
    }
}
