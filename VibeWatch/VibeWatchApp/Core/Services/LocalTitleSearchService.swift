import Foundation

/// Instant, offline-first results for the search screen.
///
/// Remote search costs a 350 ms debounce plus a TMDB round trip, and until it returns the screen
/// has nothing to show. The device already holds titles the user cares about most — everything in
/// their lists, plus whatever detail pages they have opened — so those can be on screen before the
/// first network packet leaves.
///
/// This is a hint, not a replacement: TMDB results overwrite these as soon as they arrive.
protocol LocalTitleSearching: Sendable {
    func search(matching query: String, limit: Int) async -> [SearchResult]
}

struct SQLiteLocalTitleSearch: LocalTitleSearching {
    private let db: SQLiteService

    init(db: SQLiteService = .shared) {
        self.db = db
    }

    func search(matching query: String, limit: Int = 20) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        // LIKE with a leading wildcard cannot use an index, so both tables are scanned. They are
        // small (a user's library and the detail cache) and this runs off the main thread, so the
        // scan costs far less than the round trip it is covering for.
        let prefix = "\(trimmed)%"
        let anywhere = "%\(trimmed)%"

        let sql = """
            SELECT media_id, media_type, title, poster_path, overview, release_date,
                   vote_average, vote_count, is_prefix,
                   -- Deliberate: with a MIN() in the result set, SQLite takes the bare columns
                   -- from the row that produced that minimum. Without it, a title present both in
                   -- a list and in the detail cache would return an arbitrary one of the two, and
                   -- the list row is the richer one (rating, release date).
                   MIN(source_rank) AS source_rank
            FROM (
                SELECT media_id, media_type, title, poster_path, overview, release_date,
                       vote_average, vote_count,
                       CASE WHEN title LIKE ? THEN 0 ELSE 1 END AS is_prefix,
                       0 AS source_rank
                FROM list_items
                WHERE deleted_at IS NULL AND title LIKE ?

                UNION ALL

                SELECT tmdb_id AS media_id, media_type, title, poster_path, overview, NULL AS release_date,
                       NULL AS vote_average, NULL AS vote_count,
                       CASE WHEN title LIKE ? THEN 0 ELSE 1 END AS is_prefix,
                       1 AS source_rank
                FROM media_details_cache
                WHERE deleted_at IS NULL AND title LIKE ?
            )
            GROUP BY media_id, media_type
            ORDER BY is_prefix ASC, source_rank ASC, title ASC
            LIMIT ?
        """

        do {
            let rows = try await db.queryRaw(
                sql,
                parameters: [prefix, anywhere, prefix, anywhere, limit]
            )
            return rows.compactMap(Self.makeResult)
        } catch {
            // A failure here must never break search: the remote path still runs.
            Logger.debug("[LocalTitleSearch] Local lookup failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func makeResult(from row: [String: Any]) -> SearchResult? {
        guard let mediaId = row["media_id"] as? Int,
              let mediaType = row["media_type"] as? String,
              let title = row["title"] as? String,
              mediaType == "movie" || mediaType == "tv" else { return nil }

        return SearchResult(
            id: mediaId,
            mediaType: mediaType,
            title: mediaType == "movie" ? title : nil,
            name: mediaType == "tv" ? title : nil,
            overview: row["overview"] as? String,
            posterPath: row["poster_path"] as? String,
            backdropPath: nil,
            releaseDate: mediaType == "movie" ? row["release_date"] as? String : nil,
            firstAirDate: mediaType == "tv" ? row["release_date"] as? String : nil,
            voteAverage: row["vote_average"] as? Double,
            voteCount: row["vote_count"] as? Int
        )
    }
}
