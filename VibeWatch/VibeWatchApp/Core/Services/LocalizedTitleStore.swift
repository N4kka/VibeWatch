import Foundation

/// La cache persistente dei titoli nella lingua dell'app (tabella `localized_titles`).
///
/// **Perché esiste.** Il catalogo condiviso (§1.5) parla una lingua sola — l'inglese di TMDB —
/// e tutto ciò che lo rispecchia (lo specchio `tv_tracking`, quindi la schermata Tracking e il
/// diario) la eredita: titoli delle serie E nomi degli episodi. La schermata Tracking però ha
/// il budget di §13.6: zero rete per disegnarsi. Quindi la localizzazione non può essere una
/// chiamata al momento del disegno: è una cache locale che si legge in JOIN al primo fotogramma
/// e si riempie in background, una volta per titolo e per lingua.
///
/// **Gli episodi si riempiono per stagione, non per episodio**: una chiamata a
/// `getTVSeasonDetails` porta i nomi di tutta la stagione, quindi il costo è una richiesta per
/// (serie, stagione) e non una per riga della timeline.
///
/// **Cosa non è.** Non è sincronizzata e non deve esserlo: ogni dispositivo se la riempie nella
/// propria lingua. E non è un'autorità: il titolo del catalogo resta il ripiego — un titolo vero
/// in una lingua sbagliata batte un buco.
@MainActor
final class LocalizedTitleStore {
    static let shared = LocalizedTitleStore()

    /// Un episodio dentro una serie. Il nome della serie viaggia a parte (chiave con -1).
    struct EpisodeRef: Hashable {
        let season: Int
        let episode: Int
    }

    private let sqlite: SQLiteService
    private let language: @MainActor () -> String
    private let fetchRemote: (String, Int) async -> String?
    private let fetchSeason: (Int, Int) async -> [Int: String]?

    init(
        sqlite: SQLiteService = .shared,
        language: @escaping @MainActor () -> String = { LocalizationManager.shared.currentLanguage.id },
        fetchRemote: @escaping (String, Int) async -> String? = { mediaType, id in
            // TMDBService chiede gia' nella lingua dell'app (parametro `language` di ogni
            // richiesta): qui non si traduce niente, si chiede a chi sa.
            if mediaType == "movie" {
                return try? await TMDBService.shared.getMovieDetails(id: id).title
            }
            return try? await TMDBService.shared.getTVShowDetails(id: id).name
        },
        fetchSeason: @escaping (Int, Int) async -> [Int: String]? = { showId, season in
            guard let detail = try? await TMDBService.shared.getTVSeasonDetails(
                showId: showId, seasonNumber: season) else { return nil }
            return Dictionary(detail.episodes.map { ($0.episodeNumber, $0.name) },
                              uniquingKeysWith: { first, _ in first })
        }
    ) {
        self.sqlite = sqlite
        self.language = language
        self.fetchRemote = fetchRemote
        self.fetchSeason = fetchSeason
    }

    // MARK: - Serie e film

    /// Un titolo, dalla cache o — se manca — da TMDB, memorizzato per la prossima volta.
    /// `nil` quando non c'è né in cache né in rete: il chiamante ha il suo ripiego.
    func title(mediaType: String, tmdbId: Int) async -> String? {
        if let cached = await cachedTitles(mediaType: mediaType, ids: [tmdbId])[tmdbId] {
            return cached
        }
        guard let fetched = await fetchRemote(mediaType, tmdbId) else { return nil }
        await store(mediaType: mediaType, tmdbId: tmdbId, title: fetched)
        return fetched
    }

    /// I titoli già in cache per la lingua corrente. Solo lettura locale, mai rete: è la parte
    /// che può stare dentro il primo fotogramma.
    func cachedTitles(mediaType: String, ids: [Int]) async -> [Int: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT tmdb_id, title FROM localized_titles
            WHERE media_type = ? AND language = ?
              AND season_number = -1 AND episode_number = -1
              AND tmdb_id IN (\(placeholders))
            """
        let params: [Any] = [mediaType, language()] + ids
        guard let rows = try? await sqlite.queryRaw(sql, parameters: params) else { return [:] }

        var result: [Int: String] = [:]
        for row in rows {
            let id = (row["tmdb_id"] as? Int64).map(Int.init) ?? row["tmdb_id"] as? Int
            if let id, let title = row["title"] as? String {
                result[id] = title
            }
        }
        return result
    }

    /// Riempie i buchi della cache per la lingua corrente. Restituisce `true` se ha scritto
    /// almeno un titolo — il chiamante allora rilegge; `false` significa "niente di nuovo",
    /// che chiude il giro senza rincorrersi: un fetch fallito non scrive, quindi non rilancia.
    @discardableResult
    func refreshMissing(mediaType: String, ids: Set<Int>) async -> Bool {
        let cached = await cachedTitles(mediaType: mediaType, ids: Array(ids))
        let missing = ids.subtracting(cached.keys)
        guard !missing.isEmpty else { return false }

        var wrote = false
        for id in missing {
            if let title = await fetchRemote(mediaType, id) {
                await store(mediaType: mediaType, tmdbId: id, title: title)
                wrote = true
            }
        }
        return wrote
    }

    // MARK: - Episodi

    /// I nomi episodio già in cache per una serie, lingua corrente. Legge tutte le righe della
    /// serie e filtra in memoria: una serie ha al più qualche centinaio di episodi, e la query
    /// senza row-value resta banale.
    func cachedEpisodeNames(showId: Int, refs: [EpisodeRef]) async -> [EpisodeRef: String] {
        guard !refs.isEmpty else { return [:] }
        let sql = """
            SELECT season_number, episode_number, title FROM localized_titles
            WHERE media_type = 'episode' AND tmdb_id = ? AND language = ?
            """
        guard let rows = try? await sqlite.queryRaw(sql, parameters: [showId, language()]) else {
            return [:]
        }

        let wanted = Set(refs)
        var result: [EpisodeRef: String] = [:]
        for row in rows {
            let s = (row["season_number"] as? Int64).map(Int.init) ?? row["season_number"] as? Int
            let e = (row["episode_number"] as? Int64).map(Int.init) ?? row["episode_number"] as? Int
            guard let s, let e else { continue }
            let ref = EpisodeRef(season: s, episode: e)
            if wanted.contains(ref), let title = row["title"] as? String {
                result[ref] = title
            }
        }
        return result
    }

    /// Riempie i nomi episodio mancanti, una chiamata per stagione. Il contratto è lo stesso di
    /// `refreshMissing`: `true` solo se almeno un episodio **mancante** ha ricevuto il suo nome.
    /// Una stagione che TMDB restituisce senza l'episodio cercato (numerazioni divergenti, §6)
    /// risponde `false` e non fa ricaricare nessuno.
    @discardableResult
    func refreshMissingEpisodeNames(showId: Int, refs: Set<EpisodeRef>) async -> Bool {
        let cached = await cachedEpisodeNames(showId: showId, refs: Array(refs))
        let missing = refs.subtracting(cached.keys)
        guard !missing.isEmpty else { return false }

        var wrote = false
        for season in Set(missing.map(\.season)) {
            guard let names = await fetchSeason(showId, season) else { continue }
            // Si memorizza l'intera stagione, non solo i buchi: il prossimo episodio della
            // timeline è quasi sempre nella stessa stagione, e la chiamata è già stata pagata.
            for (episode, name) in names where !name.isEmpty {
                await store(mediaType: "episode", tmdbId: showId, title: name,
                            season: season, episode: episode)
                if missing.contains(EpisodeRef(season: season, episode: episode)) {
                    wrote = true
                }
            }
        }
        return wrote
    }

    // MARK: - Scrittura

    private func store(mediaType: String, tmdbId: Int, title: String,
                       season: Int = -1, episode: Int = -1) async {
        try? await sqlite.upsert(table: "localized_titles", rows: [[
            "media_type": mediaType,
            "tmdb_id": tmdbId,
            "season_number": season,
            "episode_number": episode,
            "language": language(),
            "title": title,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]])
    }
}
