import Foundation

/// Una riga del diario di §9.3: un evento di visione con ciò che serve a disegnarlo.
struct DiaryEntry: Identifiable, Equatable {
    let id: String
    let mediaType: String          // "movie" | "tv"
    let tmdbId: Int                // show id per tv, movie id per i film
    let title: String?             // show_name dallo specchio; nil per i film (si risolve dopo)
    let episodeLabel: String?      // "S1E2" per gli episodi
    let posterPath: String?
    let watchedAt: Date
    let isInferred: Bool           // §3.2: la data e' dedotta, non dichiarata dall'utente
}

/// SPEC v3 §9.3 — il diario si legge dalla cache locale, zero rete.
///
/// La finestra e' quella del pull: 12 mesi di `watch_events` (§5). Il diario oltre i 12 mesi e'
/// Pro (§10) e passera' dal server — qui non c'e' niente da nascondere perche' la cache piu'
/// vecchia di un anno non esiste proprio.
///
/// I nomi delle serie arrivano dal LEFT JOIN con lo specchio `tv_tracking` (il catalogo incluso
/// nella vista di §9.2); i film un catalogo locale non ce l'hanno, quindi `title` resta nil e lo
/// risolve il chiamante, meglio se con cache.
@MainActor
final class LocalDiaryRepository {
    static let shared = LocalDiaryRepository()

    private let sqlite: SQLiteService
    private let currentUserId: @MainActor () -> String?

    init(sqlite: SQLiteService = .shared,
         currentUserId: @escaping @MainActor () -> String? = { AuthService.shared.currentUser?.id }) {
        self.sqlite = sqlite
        self.currentUserId = currentUserId
    }

    /// Una pagina in ordine cronologico inverso. `watched_at` decrescente con `id` a chiudere:
    /// due eventi nello stesso istante (un "segna stagione") non fanno ballare le pagine.
    func page(limit: Int, offset: Int) async throws -> [DiaryEntry] {
        guard let userId = currentUserId() else { return [] }
        let rows = try await sqlite.queryRaw(
            """
            SELECT we.id, we.media_type, we.tmdb_show_id, we.season_number, we.episode_number,
                   we.tmdb_movie_id, we.watched_at, we.watched_at_precision,
                   tt.show_name, tt.show_poster_path
            FROM watch_events we
            LEFT JOIN tv_tracking tt
              ON tt.user_id = we.user_id AND tt.tmdb_show_id = we.tmdb_show_id
            WHERE we.user_id = ? AND we.deleted_at IS NULL
            ORDER BY we.watched_at DESC, we.id
            LIMIT ? OFFSET ?
            """,
            parameters: [userId, limit, offset])
        return rows.compactMap(Self.entry(from:))
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func entry(from row: [String: Any]) -> DiaryEntry? {
        guard let id = row["id"] as? String,
              let mediaType = row["media_type"] as? String,
              let watchedRaw = row["watched_at"] as? String,
              let watchedAt = isoWithFraction.date(from: watchedRaw) ?? iso.date(from: watchedRaw)
        else { return nil }

        let intValue: (String) -> Int? = { key in
            (row[key] as? Int64).map(Int.init) ?? row[key] as? Int
        }

        if mediaType == "tv" {
            guard let showId = intValue("tmdb_show_id") else { return nil }
            var label: String?
            if let s = intValue("season_number"), let e = intValue("episode_number") {
                label = "S\(s)E\(e)"
            }
            return DiaryEntry(
                id: id, mediaType: "tv", tmdbId: showId,
                title: row["show_name"] as? String,
                episodeLabel: label,
                posterPath: row["show_poster_path"] as? String,
                watchedAt: watchedAt,
                isInferred: (row["watched_at_precision"] as? String) == "inferred")
        } else {
            guard let movieId = intValue("tmdb_movie_id") else { return nil }
            return DiaryEntry(
                id: id, mediaType: "movie", tmdbId: movieId,
                title: nil, episodeLabel: nil, posterPath: nil,
                watchedAt: watchedAt,
                isInferred: (row["watched_at_precision"] as? String) == "inferred")
        }
    }
}
