import Foundation

/// La cache persistente dei titoli nella lingua dell'app (tabella `localized_titles`).
///
/// **Perché esiste.** Il catalogo condiviso (§1.5) parla una lingua sola — l'inglese di TMDB —
/// e tutto ciò che lo rispecchia (lo specchio `tv_tracking`, quindi la schermata Tracking e il
/// diario) la eredita. La schermata Tracking però ha il budget di §13.6: zero rete per
/// disegnarsi. Quindi la localizzazione non può essere una chiamata al momento del disegno: è
/// una cache locale che si legge in JOIN al primo fotogramma e si riempie in background, una
/// volta per titolo e per lingua.
///
/// **Cosa non è.** Non è sincronizzata e non deve esserlo: ogni dispositivo se la riempie nella
/// propria lingua. E non è un'autorità: il titolo del catalogo resta il ripiego — un titolo vero
/// in una lingua sbagliata batte un buco.
@MainActor
final class LocalizedTitleStore {
    static let shared = LocalizedTitleStore()

    private let sqlite: SQLiteService
    private let language: @MainActor () -> String
    private let fetchRemote: (String, Int) async -> String?

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
        }
    ) {
        self.sqlite = sqlite
        self.language = language
        self.fetchRemote = fetchRemote
    }

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
            WHERE media_type = ? AND language = ? AND tmdb_id IN (\(placeholders))
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

    private func store(mediaType: String, tmdbId: Int, title: String) async {
        try? await sqlite.upsert(table: "localized_titles", rows: [[
            "media_type": mediaType,
            "tmdb_id": tmdbId,
            "language": language(),
            "title": title,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]])
    }
}
