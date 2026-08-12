import Foundation

protocol TrackingRepositoryProtocol {
    /// Le sezioni della schermata Tracking, **già ordinate e già in bucket**.
    ///
    /// La firma è deliberatamente questa e non `fetchRows()`: §1.1 dice che il ViewModel richiede
    /// la lista già ordinata al repository, e che il progresso non si ricalcola nel client. Se
    /// questo metodo restituisse righe grezze, l'ordinamento tornerebbe a vivere nella UI — dove
    /// stava, e da dove va tolto.
    func fetchSections() async throws -> TrackingSections
}

/// SPEC v3 §9.2 / §13.6 — legge la schermata Tracking dalla cache locale, senza rete.
///
/// Non c'è una controparte `Live`: **non deve esistere**. Se questo repository potesse cadere su
/// una chiamata di rete, il requisito di §13.6 ("se serve rete per mostrare la lista, il lavoro è
/// sbagliato") sarebbe violato dal primo utente con la connessione lenta, cioè proprio quello che
/// il fallback vorrebbe aiutare. Le righe arrivano dal pull di `v_tv_tracking` e `v_tv_timeline`;
/// se la cache è vuota, la schermata mostra il proprio stato vuoto e il sync la riempirà.
@MainActor
final class LocalTrackingRepository: TrackingRepositoryProtocol {
    static let shared = LocalTrackingRepository()

    private let sqlite: SQLiteService
    private let currentUserId: @MainActor () -> String?
    private let language: @MainActor () -> String

    init(
        sqlite: SQLiteService = .shared,
        currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id },
        language: @escaping @MainActor () -> String = { LocalizationManager.shared.currentLanguage.id }
    ) {
        self.sqlite = sqlite
        self.currentUserId = currentUserId
        self.language = language
    }

    func fetchSections() async throws -> TrackingSections {
        guard let userId = currentUserId() else { return TrackingSections() }

        async let rows = fetchRows(userId: userId)
        async let entries = fetchTimeline(userId: userId)

        var result = TrackingSections()
        result.sections = try await group(rows: rows)
        result.timeline = try await group(timeline: entries)
        return result
    }

    // MARK: - Lettura

    private func fetchRows(userId: String) async throws -> [TrackingRow] {
        // L'ordinamento è qui, in SQL, e non in Swift: è l'indice `idx_tv_tracking_bucket` a
        // pagarlo, e su 430 serie la differenza fra ordinare nel database e ordinare in memoria
        // dopo aver costruito 430 struct è tutta dentro il budget di 300 ms di §13.6.
        //
        // `backlog_since DESC`: più recente in cima (§3.3). I NULL vanno in fondo — sono le serie
        // in pari, che nella loro sezione non hanno un arretrato da confrontare.
        // La JOIN su `localized_titles` resta dentro §13.6: è una lettura locale come il resto.
        // Il titolo del catalogo (una lingua sola, §1.5) fa da ripiego finché la cache non ha
        // quello nella lingua dell'app — la riempie il ViewModel, in background, dopo il disegno.
        let sql = """
        SELECT t.tmdb_show_id, t.user_status, t.bucket, t.watched_count, t.aired_count,
               t.total_count, t.next_season, t.next_episode,
               COALESCE(ln.title, t.next_episode_name) AS next_episode_name,
               t.next_air_date, t.is_next_available, t.backlog_since, t.last_watched_at,
               COALESCE(lt.title, t.show_name) AS show_name,
               t.show_poster_path, t.next_still_path
          FROM tv_tracking t
          LEFT JOIN localized_titles lt
            ON lt.media_type = 'tv' AND lt.tmdb_id = t.tmdb_show_id AND lt.language = ?
          LEFT JOIN localized_titles ln
            ON ln.media_type = 'episode' AND ln.tmdb_id = t.tmdb_show_id
           AND ln.season_number = t.next_season AND ln.episode_number = t.next_episode
           AND ln.language = ?
         WHERE t.user_id = ?
         ORDER BY (t.backlog_since IS NULL), t.backlog_since DESC, show_name COLLATE NOCASE ASC
        """

        return try await sqlite.queryRaw(sql, parameters: [language(), language(), userId])
            .compactMap(Self.row(from:))
    }

    private func fetchTimeline(userId: String) async throws -> [TimelineEntry] {
        let sql = """
        SELECT t.id, t.tmdb_show_id, COALESCE(lt.title, t.show_name) AS show_name,
               t.show_poster_path, t.season_number, t.episode_number,
               COALESCE(le.title, t.episode_name) AS episode_name,
               t.air_date, t.still_path, t.is_special
          FROM tv_timeline t
          LEFT JOIN localized_titles lt
            ON lt.media_type = 'tv' AND lt.tmdb_id = t.tmdb_show_id AND lt.language = ?
          LEFT JOIN localized_titles le
            ON le.media_type = 'episode' AND le.tmdb_id = t.tmdb_show_id
           AND le.season_number = t.season_number AND le.episode_number = t.episode_number
           AND le.language = ?
         WHERE t.user_id = ?
         ORDER BY t.air_date ASC, show_name COLLATE NOCASE ASC
        """

        return try await sqlite.queryRaw(sql, parameters: [language(), language(), userId])
            .compactMap(Self.entry(from:))
    }

    // MARK: - Derivazione per la fusione ListsView↔Tracking

    /// Una riga TV già classificata secondo le regole della fusione (2026-08-02, decise
    /// dall'utente): watchlist TV = bucket `not_started` ∪ `for_later`, seen TV = `up_to_date`;
    /// archiviate e droppate non compaiono, una serie a metà è "in corso" e non è ancora "vista".
    struct FusedListRow {
        let showId: Int
        let title: String
        let posterPath: String?
        /// Per una "vista" è quando l'hai finita (con ripieghi onesti), per le altre
        /// l'ultimo aggiornamento dello stato.
        let addedAt: Date
        let isSeen: Bool
    }

    /// Le righe TV che ListsView, le stats locali e la personalizzazione Discovery derivano
    /// dallo specchio `tv_tracking` invece che da `list_items`.
    ///
    /// UN punto solo apposta: dopo la fusione, `AnalyticsInsightsService` e
    /// `UserPreferenceManager` leggevano ancora le liste legacy e vedevano meno serie di quelle
    /// che ListsView mostra — la copia che diverge, di nuovo. Chiunque abbia bisogno delle "TV
    /// in watchlist/viste" passa da qui; `ListManager` ci mappa sopra i suoi `MediaListItem`.
    ///
    /// La watchlist TV comprende anche `up_next` e `stale` (2026-08-04): con i soli
    /// `not_started`/`for_later`, una serie con episodi visti non poteva MAI comparirci — il
    /// ricalcolo server la spostava in un bucket che nessuna lista leggeva, così "Aggiunto alla
    /// watchlist" mostrava il toast e non cambiava niente (né checkmark né riga in ListsView).
    /// Semantica risultante, alla TV Time: watchlist = serie che segui e non hai finito;
    /// "viste" = `up_to_date`. Il toggle-off resta "smetti di seguire" (`dropped`).
    func fusedListRows(userId: String) async throws -> [FusedListRow] {
        let sql = """
            SELECT t.tmdb_show_id, t.bucket, t.next_season,
                   COALESCE(lt.title, t.show_name) AS title,
                   t.show_poster_path, t.updated_at, t.completed_at, t.last_watched_at
              FROM tv_tracking t
              LEFT JOIN localized_titles lt
                ON lt.media_type = 'tv' AND lt.tmdb_id = t.tmdb_show_id AND lt.language = ?
             WHERE t.user_id = ?
               AND t.bucket IN ('not_started', 'for_later', 'up_next', 'stale', 'up_to_date')
        """

        return try await sqlite.queryRaw(sql, parameters: [language(), userId]).compactMap { row in
            guard let showId = Self.int(row["tmdb_show_id"]),
                  let bucket = row["bucket"] as? String,
                  // Senza nome non c'è niente da mostrare: capita solo se il catalogo non ha
                  // ancora la serie, e in quel caso è la card del Tracking il posto dove appare.
                  let title = row["title"] as? String, !title.isEmpty else { return nil }

            // "Vista" vuol dire finita, non "in pari per ora": una serie con un episodio futuro
            // già annunciato (`next_season` valorizzato) resta in watchlist, e il chip "Visto" del
            // dettaglio — che legge questa stessa lista — non risulta selezionato. Quando
            // l'episodio esce, il cron notturno sposta il bucket a `up_next` e la riga torna dove
            // deve senza che il client debba accorgersene.
            let isSeen = bucket == "up_to_date" && Self.int(row["next_season"]) == nil
            let addedAt: Date
            if isSeen {
                addedAt = Self.date(row["completed_at"])
                    ?? Self.date(row["last_watched_at"])
                    ?? Self.date(row["updated_at"])
                    ?? Date()
            } else {
                addedAt = Self.date(row["updated_at"]) ?? Date()
            }

            return FusedListRow(
                showId: showId,
                title: title,
                posterPath: row["show_poster_path"] as? String,
                addedAt: addedAt,
                isSeen: isSeen
            )
        }
    }

    // MARK: - Raggruppamento

    private func group(rows: [TrackingRow]) -> [(bucket: TrackingBucket, rows: [TrackingRow])] {
        let byBucket = Dictionary(grouping: rows, by: \.bucket)
        // `displayOrder` e non le chiavi del dizionario: l'ordine delle sezioni è una decisione di
        // §9.2, non l'ordine in cui il database ha restituito le righe.
        return TrackingBucket.displayOrder.compactMap { bucket in
            guard let rows = byBucket[bucket], !rows.isEmpty else { return nil }
            return (bucket, rows)
        }
    }

    private func group(timeline: [TimelineEntry]) -> [(group: TimelineGroup, entries: [TimelineEntry])] {
        let byGroup = Dictionary(grouping: timeline) { TimelineGroup.of($0.airDate) }
        return TimelineGroup.allCases.compactMap { group in
            guard let entries = byGroup[group], !entries.isEmpty else { return nil }
            return (group, entries)
        }
    }

    // MARK: - Mappatura

    /// Le date arrivano da SQLite come testo ISO. Un formato non riconosciuto diventa `nil` e non
    /// una data inventata: una data sbagliata sposterebbe la serie nella sezione sbagliata, che è
    /// peggio di un campo vuoto.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return ISO8601DateFormatter.tracking.date(from: text)
            ?? ISO8601DateFormatter.trackingWithFraction.date(from: text)
            ?? DateFormatter.trackingDayOnly.date(from: text)
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let i = value as? Int64 { return Int(i) }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func row(from raw: [String: Any]) -> TrackingRow? {
        guard let showId = int(raw["tmdb_show_id"]) else { return nil }

        // Un bucket sconosciuto NON diventa `up_next`: significherebbe mettere in cima alla
        // schermata una serie che il server ha classificato in un modo che questa versione
        // dell'app non conosce. Si scarta la riga, che è visibile in un elenco più corto, mentre
        // una riga nel posto sbagliato non lo è.
        guard let bucketText = raw["bucket"] as? String,
              let bucket = TrackingBucket(rawValue: bucketText) else { return nil }

        return TrackingRow(
            showId: showId,
            userStatus: raw["user_status"] as? String ?? "active",
            bucket: bucket,
            watchedCount: int(raw["watched_count"]) ?? 0,
            airedCount: int(raw["aired_count"]) ?? 0,
            totalCount: int(raw["total_count"]) ?? 0,
            nextSeason: int(raw["next_season"]),
            nextEpisode: int(raw["next_episode"]),
            nextEpisodeName: raw["next_episode_name"] as? String,
            nextAirDate: date(raw["next_air_date"]),
            isNextAvailable: (int(raw["is_next_available"]) ?? 0) != 0,
            backlogSince: date(raw["backlog_since"]),
            lastWatchedAt: date(raw["last_watched_at"]),
            showName: raw["show_name"] as? String,
            posterPath: raw["show_poster_path"] as? String,
            nextStillPath: raw["next_still_path"] as? String
        )
    }

    private static func entry(from raw: [String: Any]) -> TimelineEntry? {
        guard let id = raw["id"] as? String,
              let showId = int(raw["tmdb_show_id"]),
              let season = int(raw["season_number"]),
              let episode = int(raw["episode_number"]),
              // Senza data non c'è un gruppo in cui metterla: la timeline è fatta di date.
              let airDate = date(raw["air_date"]) else { return nil }

        return TimelineEntry(
            id: id,
            showId: showId,
            showName: raw["show_name"] as? String,
            posterPath: raw["show_poster_path"] as? String,
            seasonNumber: season,
            episodeNumber: episode,
            episodeName: raw["episode_name"] as? String,
            airDate: airDate,
            stillPath: raw["still_path"] as? String,
            isSpecial: (int(raw["is_special"]) ?? 0) != 0
        )
    }
}

private extension ISO8601DateFormatter {
    static let tracking: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let trackingWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private extension DateFormatter {
    /// `next_air_date` e `air_date` sono `date` in Postgres: arrivano come `2026-08-14`, senza ora.
    static let trackingDayOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
