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

    init(
        sqlite: SQLiteService = .shared,
        currentUserId: @escaping @MainActor () -> String? = { SupabaseService.shared.currentUser?.id }
    ) {
        self.sqlite = sqlite
        self.currentUserId = currentUserId
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
        let sql = """
        SELECT tmdb_show_id, user_status, bucket, watched_count, aired_count, total_count,
               next_season, next_episode, next_episode_name, next_air_date, is_next_available,
               backlog_since, last_watched_at, show_name, show_poster_path, next_still_path
          FROM tv_tracking
         WHERE user_id = ?
         ORDER BY (backlog_since IS NULL), backlog_since DESC, show_name COLLATE NOCASE ASC
        """

        return try await sqlite.queryRaw(sql, parameters: [userId]).compactMap(Self.row(from:))
    }

    private func fetchTimeline(userId: String) async throws -> [TimelineEntry] {
        let sql = """
        SELECT id, tmdb_show_id, show_name, show_poster_path, season_number, episode_number,
               episode_name, air_date, still_path, is_special
          FROM tv_timeline
         WHERE user_id = ?
         ORDER BY air_date ASC, show_name COLLATE NOCASE ASC
        """

        return try await sqlite.queryRaw(sql, parameters: [userId]).compactMap(Self.entry(from:))
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
