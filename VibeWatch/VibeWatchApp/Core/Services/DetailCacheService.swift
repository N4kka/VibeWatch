import Foundation

/// Service for caching Movie/TV Show detail pages in local SQLite database
/// Enables offline viewing of previously viewed content (compliant with Apple Guideline 5.2.3)
///
/// COMPLIANCE NOTE: This service caches METADATA ONLY from TMDB API, NOT video content.
/// - Caches: titles, descriptions, cast, ratings, poster URLs (metadata)
/// - Does NOT cache: YouTube videos, streaming files, or downloadable media
/// - Fully compliant with TMDB API Terms: https://www.themoviedb.org/settings/api
@MainActor
class DetailCacheService {
    static let shared = DetailCacheService()

    private let db = SQLiteService.shared
    private let cacheExpiration: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    private init() {}

    // MARK: - Movie Details Cache

    /// Cache movie details for offline viewing
    func cacheMovieDetails(
        movie: Movie,
        credits: Credits?,
        videos: [Video],
        watchProviders: CountryProviders?,
        similarMovies: [Movie],
        imdbId: String?
    ) async throws {
        let now = Date()
        let expiresAt = now.addingTimeInterval(cacheExpiration)
        let formatter = ISO8601DateFormatter()

        // Serialize complex objects to JSON
        let creditsJSON = try? JSONEncoder().encode(credits).base64EncodedString()
        let videosJSON = try? JSONEncoder().encode(videos).base64EncodedString()
        let providersJSON = try? JSONEncoder().encode(watchProviders).base64EncodedString()
        let similarJSON = try? JSONEncoder().encode(similarMovies).base64EncodedString()

        let values: [String: Any] = [
            "id": UUID().uuidString,
            "media_id": movie.id,
            "media_type": "movie",
            "title": movie.title,
            "overview": movie.overview,
            "poster_path": movie.posterPath ?? "",
            "backdrop_path": movie.backdropPath ?? "",
            "release_date": movie.releaseDate ?? "",
            "vote_average": movie.voteAverage,
            "runtime": movie.runtime ?? 0,
            "genres": (movie.genreIds?.map { String($0) }.joined(separator: ",")) ?? "",
            "credits_json": creditsJSON ?? "",
            "videos_json": videosJSON ?? "",
            "providers_json": providersJSON ?? "",
            "similar_json": similarJSON ?? "",
            "imdb_id": imdbId ?? "",
            "cached_at": formatter.string(from: now),
            "expires_at": formatter.string(from: expiresAt)
        ]

        // Check if already cached (including soft-deleted entries), update if exists
        let existing = try await db.queryRaw("""
            SELECT id FROM detail_cache
            WHERE media_id = ? AND media_type = 'movie'
        """, parameters: [movie.id])

        if let existingId = existing.first?["id"] as? String {
            // Update existing (and clear deleted_at to "undelete" it)
            var updateValues = values
            updateValues["deleted_at"] = NSNull()  // Clear deleted_at
            try await db.update("detail_cache", values: updateValues, where: "id = ?", parameters: [existingId])
            print("✅ [DetailCache] Updated cached movie: \(movie.title)")
        } else {
            // Insert new
            _ = try await db.insert("detail_cache", values: values)
            print("✅ [DetailCache] Cached new movie: \(movie.title)")
        }
    }

    /// Get cached movie details (returns nil if not found or expired)
    func getCachedMovieDetails(movieId: Int) async throws -> CachedMovieDetail? {
        let now = ISO8601DateFormatter().string(from: Date())

        // First, check if there's ANY cache entry for this movie (for debugging)
        let allRows = try await db.queryRaw("""
            SELECT media_id, expires_at, deleted_at FROM detail_cache
            WHERE media_id = ? AND media_type = 'movie'
        """, parameters: [movieId])

        if allRows.isEmpty {
            print("📭 [DetailCache] No cache entry exists for movie ID \(movieId)")
        } else {
            let row = allRows.first!
            let expiresAt = row["expires_at"] as? String ?? "nil"
            let deletedAt = row["deleted_at"] as? String ?? "nil"
            print("🔍 [DetailCache] Found cache entry for movie ID \(movieId): expires_at=\(expiresAt), deleted_at=\(deletedAt), now=\(now)")
        }

        let rows = try await db.queryRaw("""
            SELECT * FROM detail_cache
            WHERE media_id = ? AND media_type = 'movie'
            AND expires_at > ? AND deleted_at IS NULL
        """, parameters: [movieId, now])

        guard let row = rows.first else {
            print("📭 [DetailCache] No valid cached movie found for ID \(movieId) (expired or deleted)")
            return nil
        }

        return try parseCachedMovieDetail(from: row)
    }

    // MARK: - TV Show Details Cache

    /// Cache TV show details for offline viewing
    func cacheTVShowDetails(
        tvShow: TVShow,
        credits: Credits?,
        videos: [Video],
        watchProviders: CountryProviders?,
        similarShows: [TVShow],
        imdbId: String?
    ) async throws {
        let now = Date()
        let expiresAt = now.addingTimeInterval(cacheExpiration)
        let formatter = ISO8601DateFormatter()

        // Serialize complex objects to JSON
        let creditsJSON = try? JSONEncoder().encode(credits).base64EncodedString()
        let videosJSON = try? JSONEncoder().encode(videos).base64EncodedString()
        let providersJSON = try? JSONEncoder().encode(watchProviders).base64EncodedString()
        let similarJSON = try? JSONEncoder().encode(similarShows).base64EncodedString()

        let values: [String: Any] = [
            "id": UUID().uuidString,
            "media_id": tvShow.id,
            "media_type": "tv",
            "title": tvShow.name,
            "overview": tvShow.overview,
            "poster_path": tvShow.posterPath ?? "",
            "backdrop_path": tvShow.backdropPath ?? "",
            "release_date": tvShow.firstAirDate ?? "",
            "vote_average": tvShow.voteAverage,
            "runtime": 0, // TV shows don't have single runtime
            "genres": (tvShow.genreIds?.map { String($0) }.joined(separator: ",")) ?? "",
            "credits_json": creditsJSON ?? "",
            "videos_json": videosJSON ?? "",
            "providers_json": providersJSON ?? "",
            "similar_json": similarJSON ?? "",
            "imdb_id": imdbId ?? "",
            "cached_at": formatter.string(from: now),
            "expires_at": formatter.string(from: expiresAt)
        ]

        // Check if already cached (including soft-deleted entries), update if exists
        let existing = try await db.queryRaw("""
            SELECT id FROM detail_cache
            WHERE media_id = ? AND media_type = 'tv'
        """, parameters: [tvShow.id])

        if let existingId = existing.first?["id"] as? String {
            // Update existing (and clear deleted_at to "undelete" it)
            var updateValues = values
            updateValues["deleted_at"] = NSNull()  // Clear deleted_at
            try await db.update("detail_cache", values: updateValues, where: "id = ?", parameters: [existingId])
            print("✅ [DetailCache] Updated cached TV show: \(tvShow.name)")
        } else {
            // Insert new
            _ = try await db.insert("detail_cache", values: values)
            print("✅ [DetailCache] Cached new TV show: \(tvShow.name)")
        }
    }

    /// Get cached TV show details (returns nil if not found or expired)
    func getCachedTVShowDetails(tvShowId: Int) async throws -> CachedTVShowDetail? {
        let now = ISO8601DateFormatter().string(from: Date())

        // First, check if there's ANY cache entry for this TV show (for debugging)
        let allRows = try await db.queryRaw("""
            SELECT media_id, expires_at, deleted_at FROM detail_cache
            WHERE media_id = ? AND media_type = 'tv'
        """, parameters: [tvShowId])

        if allRows.isEmpty {
            print("📭 [DetailCache] No cache entry exists for TV show ID \(tvShowId)")
        } else {
            let row = allRows.first!
            let expiresAt = row["expires_at"] as? String ?? "nil"
            let deletedAt = row["deleted_at"] as? String ?? "nil"
            print("🔍 [DetailCache] Found cache entry for TV show ID \(tvShowId): expires_at=\(expiresAt), deleted_at=\(deletedAt), now=\(now)")
        }

        let rows = try await db.queryRaw("""
            SELECT * FROM detail_cache
            WHERE media_id = ? AND media_type = 'tv'
            AND expires_at > ? AND deleted_at IS NULL
        """, parameters: [tvShowId, now])

        guard let row = rows.first else {
            print("📭 [DetailCache] No valid cached TV show found for ID \(tvShowId) (expired or deleted)")
            return nil
        }

        return try parseCachedTVShowDetail(from: row)
    }

    // MARK: - Parsing Helpers

    private func parseCachedMovieDetail(from row: [String: Any]) throws -> CachedMovieDetail {
        let genresString = row["genres"] as? String ?? ""
        let genreIds = genresString.split(separator: ",").compactMap { Int($0) }

        let movie = Movie(
            id: row["media_id"] as? Int ?? 0,
            title: row["title"] as? String ?? "",
            overview: row["overview"] as? String ?? "",
            posterPath: row["poster_path"] as? String,
            backdropPath: row["backdrop_path"] as? String,
            releaseDate: row["release_date"] as? String,
            voteAverage: row["vote_average"] as? Double ?? 0,
            voteCount: 0,
            genreIds: genreIds.isEmpty ? nil : genreIds,
            genres: nil,
            adult: false,
            originalLanguage: "",
            popularity: 0,
            runtime: row["runtime"] as? Int,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: row["imdb_id"] as? String
        )

        // Decode complex objects
        let credits = decodeFromBase64(row["credits_json"] as? String, as: Credits.self)
        let videos = decodeFromBase64(row["videos_json"] as? String, as: [Video].self) ?? []
        let providers = decodeFromBase64(row["providers_json"] as? String, as: CountryProviders.self)
        let similar = decodeFromBase64(row["similar_json"] as? String, as: [Movie].self) ?? []

        print("✅ [DetailCache] Retrieved cached movie: \(movie.title)")

        return CachedMovieDetail(
            movie: movie,
            credits: credits,
            videos: videos,
            watchProviders: providers,
            similarMovies: similar
        )
    }

    private func parseCachedTVShowDetail(from row: [String: Any]) throws -> CachedTVShowDetail {
        let genresString = row["genres"] as? String ?? ""
        let genreIds = genresString.split(separator: ",").compactMap { Int($0) }

        let tvShow = TVShow(
            id: row["media_id"] as? Int ?? 0,
            name: row["title"] as? String ?? "",
            overview: row["overview"] as? String ?? "",
            posterPath: row["poster_path"] as? String,
            backdropPath: row["backdrop_path"] as? String,
            firstAirDate: row["release_date"] as? String,
            voteAverage: row["vote_average"] as? Double ?? 0,
            voteCount: 0,
            genreIds: genreIds.isEmpty ? nil : genreIds,
            genres: nil,
            originalLanguage: "",
            popularity: 0,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: row["imdb_id"] as? String
        )

        // Decode complex objects
        let credits = decodeFromBase64(row["credits_json"] as? String, as: Credits.self)
        let videos = decodeFromBase64(row["videos_json"] as? String, as: [Video].self) ?? []
        let providers = decodeFromBase64(row["providers_json"] as? String, as: CountryProviders.self)
        let similar = decodeFromBase64(row["similar_json"] as? String, as: [TVShow].self) ?? []

        print("✅ [DetailCache] Retrieved cached TV show: \(tvShow.name)")

        return CachedTVShowDetail(
            tvShow: tvShow,
            credits: credits,
            videos: videos,
            watchProviders: providers,
            similarShows: similar
        )
    }

    private func decodeFromBase64<T: Decodable>(_ base64String: String?, as type: T.Type) -> T? {
        guard let base64String = base64String,
              !base64String.isEmpty,
              let data = Data(base64Encoded: base64String) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Cache Management

    /// Clear expired cache entries
    func clearExpiredCache() async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        _ = try await db.queryRaw("""
            UPDATE detail_cache
            SET deleted_at = ?
            WHERE expires_at <= ? AND deleted_at IS NULL
        """, parameters: [now, now])

        print("🗑️ [DetailCache] Cleared expired cache entries")
    }

    /// Clear all cached details
    func clearAllCache() async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        _ = try await db.queryRaw("""
            UPDATE detail_cache
            SET deleted_at = ?
            WHERE deleted_at IS NULL
        """, parameters: [now])

        print("🗑️ [DetailCache] Cleared all cached details")
    }
}

// MARK: - Cached Detail Models

struct CachedMovieDetail {
    let movie: Movie
    let credits: Credits?
    let videos: [Video]
    let watchProviders: CountryProviders?
    let similarMovies: [Movie]
}

struct CachedTVShowDetail {
    let tvShow: TVShow
    let credits: Credits?
    let videos: [Video]
    let watchProviders: CountryProviders?
    let similarShows: [TVShow]
}
