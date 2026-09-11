import Foundation

/// Il periodo di un wrap-up. Solo mese e anno: sono i due tagli che la gente racconta
/// ("questo mese", "il mio anno"), e ognuno in più sarebbe una voce di menu senza domanda dietro.
enum WrapUpPeriod: Equatable, Hashable, Identifiable {
    case month(year: Int, month: Int)
    case year(Int)

    var id: String {
        switch self {
        case .month(let year, let month): return "m-\(year)-\(month)"
        case .year(let year): return "y-\(year)"
        }
    }

    /// L'intervallo semiaperto [inizio, fine) nel calendario dell'utente: un wrap-up di gennaio
    /// deve finire dove comincia febbraio, non 30 giorni dopo.
    func range(calendar: Calendar = .current) -> (start: Date, end: Date)? {
        var components = DateComponents()
        switch self {
        case .month(let year, let month):
            components.year = year
            components.month = month
            components.day = 1
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            return (start, end)
        case .year(let year):
            components.year = year
            components.month = 1
            components.day = 1
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
            return (start, end)
        }
    }

    /// L'etichetta che finisce sulla card ("Agosto 2026", "2026"), nella lingua dell'utente.
    func localizedLabel(locale: Locale = .current) -> String {
        switch self {
        case .month(let year, let month):
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = 1
            guard let date = Calendar.current.date(from: components) else { return "\(year)" }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: date).capitalized(with: locale)
        case .year(let year):
            return "\(year)"
        }
    }

    /// Il mese appena concluso e l'anno in corso: i due periodi che ha senso proporre oggi.
    static func suggestions(from date: Date = Date(), calendar: Calendar = .current) -> [WrapUpPeriod] {
        let now = calendar.dateComponents([.year, .month], from: date)
        guard let year = now.year, let month = now.month else { return [] }
        let previous = month == 1 ? (year: year - 1, month: 12) : (year: year, month: month - 1)
        return [
            .month(year: year, month: month),
            .month(year: previous.year, month: previous.month),
            .year(year),
        ]
    }
}

/// Un titolo in evidenza nel wrap-up: per le serie il numero di episodi del periodo, per i film
/// il posto in griglia e basta.
struct WrapUpTitle: Identifiable, Equatable {
    let mediaType: String
    let tmdbId: Int
    var title: String?
    var posterPath: String?
    let episodes: Int
    let lastWatched: Date

    var id: String { "\(mediaType)-\(tmdbId)" }
}

/// Ciò che il periodo contiene davvero. Ogni campo è contato, nessuno stimato: `hours` è nil
/// quando i runtime non ci sono (una serie tracciata senza durate), e la card in quel caso
/// accorcia la riga invece di scrivere uno zero che sembrerebbe "non hai guardato niente".
struct WrapUpSummary: Equatable {
    let period: WrapUpPeriod
    let movies: Int
    let episodes: Int
    let hours: Int?
    let activeDays: Int
    let topTitles: [WrapUpTitle]

    var isEmpty: Bool { movies == 0 && episodes == 0 }
}

/// Il riepilogo di un periodo, letto dagli specchi locali — zero rete, come il diario (§9.3), e
/// la stessa finestra: 12 mesi di cache, quindi un wrap-up di tre anni fa non esiste perché i
/// dati non ci sono, non perché li nascondiamo.
///
/// **Due sorgenti, non una.** `watch_events` da solo direbbe "0 film" a quasi tutti: nell'app i
/// film segnati visti finiscono SOLO in `list_items` della lista `seen` — l'unico writer di
/// eventi per i film è l'import TV Time. È la stessa asimmetria che `20260803150000` ha risolto
/// server-side in `get_my_stats`, e qui si applica la stessa regola: le due sorgenti si uniscono
/// e **l'evento vince** (porta la sua data, che è più vera di "quando l'ho aggiunto ai visti").
/// Senza questa unione un utente che guarda solo film si vedrebbe restituire una card di zeri.
///
/// **Le date inferite restano fuori.** Un wrap-up è un discorso sulle DATE ("ad agosto hai
/// visto..."), e `watched_at_precision = 'inferred'` vuol dire che quella data l'abbiamo dedotta
/// noi: metterla in un mese preciso sarebbe presentare una nostra congettura come un ricordo
/// dell'utente. Lo storico importato con data vera invece entra: è roba sua.
///
/// **Il limite noto:** gli episodi senza `runtime_seconds` non contribuiscono alle ore. Il
/// server ripiega su `tmdb_episodes.runtime_minutes`, che sul client non è specchiato — le ore
/// sono quindi una soglia minima, mai una stima. Per i film il ripiego c'è: i minuti di catalogo
/// che `list_items.runtime` porta già con sé.
@MainActor
final class WrapUpBuilder {
    static let shared = WrapUpBuilder()

    private let sqlite: SQLiteService
    private let currentUserId: @MainActor () -> String?

    init(sqlite: SQLiteService = .shared,
         currentUserId: @escaping @MainActor () -> String? = { AuthService.shared.currentUser?.id }) {
        self.sqlite = sqlite
        self.currentUserId = currentUserId
    }

    func summary(for period: WrapUpPeriod) async -> WrapUpSummary {
        let empty = WrapUpSummary(period: period, movies: 0, episodes: 0,
                                  hours: nil, activeDays: 0, topTitles: [])
        guard let userId = currentUserId(), let range = period.range() else { return empty }

        // Il filtro SQL è largo un giorno per lato e guarda solo la parte data della stringa:
        // i timestamp locali convivono in più forme ("...Z", "...+00:00", con e senza frazioni)
        // e un confronto lessicografico stretto sull'ora taglierebbe righe buone al bordo del
        // periodo. La selezione vera la fa Swift sulle date parsate, qui sotto.
        let bounds = Self.dayBounds(range)

        let eventRows = (try? await sqlite.queryRaw(
            """
            SELECT we.media_type, we.tmdb_show_id, we.tmdb_movie_id, we.runtime_seconds,
                   we.watched_at, tt.show_name, tt.show_poster_path
            FROM watch_events we
            LEFT JOIN tv_tracking tt
              ON tt.user_id = we.user_id AND tt.tmdb_show_id = we.tmdb_show_id
            WHERE we.user_id = ? AND we.deleted_at IS NULL
              AND we.watched_at_precision <> 'inferred'
              AND substr(we.watched_at, 1, 10) >= ? AND substr(we.watched_at, 1, 10) <= ?
            """,
            parameters: [userId, bounds.from, bounds.to]
        )) ?? []

        // I film "visti" dell'app: titolo e poster ce li ha già la riga di lista, quindi questi
        // non hanno nemmeno bisogno del giro di arricchimento da TMDB.
        let seenMovieRows = (try? await sqlite.queryRaw(
            """
            SELECT li.media_id, li.title, li.poster_path, li.runtime, li.added_at
            FROM list_items li
            JOIN lists l ON l.id = li.list_id
            WHERE l.user_id = ? AND l.type = 'seen' AND l.deleted_at IS NULL
              AND li.deleted_at IS NULL AND li.media_type = 'movie'
              AND substr(li.added_at, 1, 10) >= ? AND substr(li.added_at, 1, 10) <= ?
            """,
            parameters: [userId, bounds.from, bounds.to]
        )) ?? []

        // I minuti di catalogo per i film, da QUALUNQUE lista li porti: servono a dare una durata
        // anche agli eventi film importati, che spesso arrivano senza `runtime_seconds`.
        let runtimeRows = (try? await sqlite.queryRaw(
            """
            SELECT media_id, MAX(runtime) AS runtime
            FROM list_items
            WHERE user_id = ? AND media_type = 'movie' AND deleted_at IS NULL AND runtime IS NOT NULL
            GROUP BY media_id
            """,
            parameters: [userId]
        )) ?? []

        // I film che hanno già un evento contato: la riga di lista non li conta una seconda volta.
        // Il confronto è su TUTTA la storia, non solo sul periodo — come fa il server: un film ha
        // una data sola, e quella dell'evento è quella buona.
        let eventMovieRows = (try? await sqlite.queryRaw(
            """
            SELECT DISTINCT tmdb_movie_id FROM watch_events
            WHERE user_id = ? AND deleted_at IS NULL AND media_type = 'movie'
              AND watched_at_precision <> 'inferred' AND tmdb_movie_id IS NOT NULL
            """,
            parameters: [userId]
        )) ?? []

        guard !eventRows.isEmpty || !seenMovieRows.isEmpty else { return empty }

        // Conteggio prima, arricchimento poi: l'aggregazione è pura e verificabile senza rete,
        // e i titoli dei film che ne mancano si risolvono sul risultato.
        let summary = Self.aggregate(
            eventRows: eventRows,
            seenMovieRows: seenMovieRows,
            movieRuntimeMinutes: Dictionary(
                runtimeRows.compactMap { row -> (Int, Int)? in
                    guard let id = Self.int(row["media_id"]), let minutes = Self.int(row["runtime"])
                    else { return nil }
                    return (id, minutes)
                },
                uniquingKeysWith: max),
            moviesWithEvents: Set(eventMovieRows.compactMap { Self.int($0["tmdb_movie_id"]) }),
            period: period,
            range: range)

        return WrapUpSummary(
            period: summary.period, movies: summary.movies, episodes: summary.episodes,
            hours: summary.hours, activeDays: summary.activeDays,
            topTitles: await Self.resolveMovieTitles(summary.topTitles))
    }

    // MARK: - Aggregazione

    /// Pura di proposito (niente rete, niente SQLite): è qui che vive la regola delle due
    /// sorgenti, ed è la regola che vale la pena verificare in un test.
    static func aggregate(eventRows: [[String: Any]],
                          seenMovieRows: [[String: Any]],
                          movieRuntimeMinutes: [Int: Int],
                          moviesWithEvents: Set<Int>,
                          period: WrapUpPeriod,
                          range: (start: Date, end: Date)) -> WrapUpSummary {
        var movies = 0
        var episodes = 0
        var seconds = 0
        var days: Set<String> = []
        var buckets: [String: WrapUpTitle] = [:]

        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        /// Un titolo entra nel periodo una volta per evento: le serie accumulano episodi, i film
        /// restano una card sola anche fra prima visione e rewatch dello stesso mese.
        func record(mediaType: String, tmdbId: Int?, title: String?, poster: String?, at date: Date) {
            days.insert(dayFormatter.string(from: calendar.startOfDay(for: date)))
            guard let id = tmdbId else { return }
            let key = "\(mediaType)-\(id)"
            if let existing = buckets[key] {
                buckets[key] = WrapUpTitle(
                    mediaType: mediaType, tmdbId: id,
                    title: existing.title ?? title,
                    posterPath: existing.posterPath ?? poster,
                    episodes: existing.episodes + 1,
                    lastWatched: max(existing.lastWatched, date))
            } else {
                buckets[key] = WrapUpTitle(
                    mediaType: mediaType, tmdbId: id, title: title, posterPath: poster,
                    episodes: 1, lastWatched: date)
            }
        }

        for row in eventRows {
            guard let mediaType = row["media_type"] as? String,
                  let watchedRaw = row["watched_at"] as? String,
                  let watchedAt = parseDate(watchedRaw),
                  watchedAt >= range.start, watchedAt < range.end else { continue }

            if mediaType == "tv" {
                episodes += 1
                seconds += int(row["runtime_seconds"]) ?? 0
                record(mediaType: "tv", tmdbId: int(row["tmdb_show_id"]),
                       title: row["show_name"] as? String,
                       poster: row["show_poster_path"] as? String, at: watchedAt)
            } else {
                movies += 1
                let movieId = int(row["tmdb_movie_id"])
                // I minuti di catalogo colmano il buco degli eventi importati senza durata.
                seconds += int(row["runtime_seconds"])
                    ?? movieId.flatMap { movieRuntimeMinutes[$0] }.map { $0 * 60 }
                    ?? 0
                // Titolo e poster dei film il server non li ha: li risolve `resolveMovieTitles`.
                record(mediaType: "movie", tmdbId: movieId, title: nil, poster: nil, at: watchedAt)
            }
        }

        for row in seenMovieRows {
            guard let movieId = int(row["media_id"]),
                  !moviesWithEvents.contains(movieId),
                  let addedRaw = row["added_at"] as? String,
                  let addedAt = parseDate(addedRaw),
                  addedAt >= range.start, addedAt < range.end else { continue }

            movies += 1
            seconds += (int(row["runtime"]) ?? 0) * 60
            record(mediaType: "movie", tmdbId: movieId,
                   title: row["title"] as? String,
                   poster: row["poster_path"] as? String, at: addedAt)
        }

        // In evidenza chi ha occupato più tempo, a parità il più recente: la griglia della card
        // tiene quattro poster e questi sono i quattro che raccontano il periodo.
        let top = buckets.values
            .sorted {
                $0.episodes != $1.episodes
                    ? $0.episodes > $1.episodes
                    : $0.lastWatched > $1.lastWatched
            }
            .prefix(4)

        return WrapUpSummary(
            period: period,
            movies: movies,
            episodes: episodes,
            hours: seconds > 0 ? max(1, seconds / 3600) : nil,
            activeDays: days.count,
            topTitles: Array(top))
    }

    /// I film in evidenza prendono titolo e poster da dove li prende il resto dell'app: prima la
    /// cache dei dettagli, poi TMDB. Un titolo che non si risolve resta un riquadro col ripiego.
    private static func resolveMovieTitles(_ titles: [WrapUpTitle]) async -> [WrapUpTitle] {
        var resolved = titles
        for index in resolved.indices where resolved[index].mediaType == "movie" {
            let movieId = resolved[index].tmdbId
            if let cached = try? await DetailCacheService.shared.getCachedMovieDetails(movieId: movieId) {
                resolved[index].title = cached.movie.title
                resolved[index].posterPath = cached.movie.posterPath
            } else if let movie = try? await TMDBService.shared.getMovieDetails(id: movieId) {
                resolved[index].title = movie.title
                resolved[index].posterPath = movie.posterPath
            }
        }
        return resolved
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    /// La forma che SQLite scrive col suo `datetime('now')` di default (spazio, niente fuso):
    /// l'app di norma inserisce ISO8601, ma una riga nata dal DEFAULT resta comunque leggibile.
    private static let sqliteDefault: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func parseDate(_ raw: String) -> Date? {
        isoWithFraction.date(from: raw) ?? iso.date(from: raw) ?? sqliteDefault.date(from: raw)
    }

    /// SQLite restituisce gli interi come Int64 o Int a seconda del percorso: un solo posto che
    /// lo sa, invece di una closure ricopiata in ogni ciclo.
    private static func int(_ value: Any?) -> Int? {
        (value as? Int64).map(Int.init) ?? value as? Int
    }

    /// Gli estremi del prefiltro SQL: un giorno di margine per lato, in UTC, perché il periodo è
    /// calcolato nel calendario locale e i timestamp sono scritti in UTC.
    private static func dayBounds(_ range: (start: Date, end: Date)) -> (from: String, to: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return (formatter.string(from: range.start.addingTimeInterval(-86_400)),
                formatter.string(from: range.end.addingTimeInterval(86_400)))
    }
}
