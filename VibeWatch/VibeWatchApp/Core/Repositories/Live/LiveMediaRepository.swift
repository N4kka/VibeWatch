import Foundation

@MainActor
final class LiveMediaRepository: MediaRepository {
    typealias MovieDetailsProvider = (Int) async throws -> Movie
    typealias TVShowDetailsProvider = (Int) async throws -> TVShow
    typealias WatchProviderLoader = (Int) async throws -> WatchProvider

    private let db: SQLiteService
    private let movieDetailsProvider: MovieDetailsProvider
    private let tvShowDetailsProvider: TVShowDetailsProvider
    private let movieWatchProvider: WatchProviderLoader
    private let tvShowWatchProvider: WatchProviderLoader
    private let metadataTTL: TimeInterval
    private let availabilityTTL: TimeInterval

    init(
        db: SQLiteService = .shared,
        movieDetailsProvider: @escaping MovieDetailsProvider = { try await TMDBService.shared.getMovieDetails(id: $0) },
        tvShowDetailsProvider: @escaping TVShowDetailsProvider = { try await TMDBService.shared.getTVShowDetails(id: $0) },
        movieWatchProvider: @escaping WatchProviderLoader = { try await TMDBService.shared.getMovieWatchProviders(id: $0) },
        tvShowWatchProvider: @escaping WatchProviderLoader = { try await TMDBService.shared.getTVShowWatchProviders(id: $0) },
        metadataTTL: TimeInterval = 7 * 24 * 60 * 60,
        availabilityTTL: TimeInterval = 12 * 60 * 60
    ) {
        self.db = db
        self.movieDetailsProvider = movieDetailsProvider
        self.tvShowDetailsProvider = tvShowDetailsProvider
        self.movieWatchProvider = movieWatchProvider
        self.tvShowWatchProvider = tvShowWatchProvider
        self.metadataTTL = metadataTTL
        self.availabilityTTL = availabilityTTL
    }

    func details(for identifier: MediaIdentifier) -> AsyncStream<MediaDetailsSnapshot?> {
        AsyncStream { continuation in
            Task { @MainActor in
                let cached = try? await cachedDetails(for: identifier)
                if let cached {
                    continuation.yield(cached.snapshot)
                }

                if cached?.isFresh != true {
                    try? await refreshDetails(for: identifier)
                    let refreshed = try? await cachedDetails(for: identifier)
                    continuation.yield(refreshed?.snapshot)
                }

                continuation.finish()
            }
        }
    }

    func availability(for identifier: MediaIdentifier, region: String) -> AsyncStream<MediaAvailabilitySnapshot?> {
        AsyncStream { continuation in
            Task { @MainActor in
                let cached = try? await cachedAvailability(for: identifier, region: region)
                if let cached {
                    continuation.yield(cached)
                }

                if cached.map({ $0.expiresAt > Date() }) != true {
                    try? await refreshAvailability(for: identifier, region: region)
                    continuation.yield(try? await cachedAvailability(for: identifier, region: region))
                }

                continuation.finish()
            }
        }
    }

    func refreshDetails(for identifier: MediaIdentifier) async throws {
        let now = Date()
        let expiresAt = now.addingTimeInterval(metadataTTL)

        switch identifier.mediaType {
        case .movie:
            let movie = try await movieDetailsProvider(identifier.id)
            try await db.upsert(table: "media_details_cache", rows: [mediaDetailsRow(
                identifier: identifier,
                title: movie.title,
                overview: movie.overview,
                posterPath: movie.posterPath,
                backdropPath: movie.backdropPath,
                cachedAt: now,
                metadataExpiresAt: expiresAt
            )])
        case .tv:
            let show = try await tvShowDetailsProvider(identifier.id)
            try await db.upsert(table: "media_details_cache", rows: [mediaDetailsRow(
                identifier: identifier,
                title: show.name,
                overview: show.overview,
                posterPath: show.posterPath,
                backdropPath: show.backdropPath,
                cachedAt: now,
                metadataExpiresAt: expiresAt
            )])
        }
    }

    func refreshAvailability(for identifier: MediaIdentifier, region: String) async throws {
        let now = Date()
        let provider = switch identifier.mediaType {
        case .movie:
            try await movieWatchProvider(identifier.id)
        case .tv:
            try await tvShowWatchProvider(identifier.id)
        }

        try await db.upsert(table: "media_availability", rows: [[
            "tmdb_id": identifier.id,
            "media_type": identifier.mediaType.rawValue,
            "region": region,
            "providers_json": try RepositoryCoding.jsonString(provider),
            "cached_at": RepositoryCoding.string(from: now),
            "expires_at": RepositoryCoding.string(from: now.addingTimeInterval(availabilityTTL)),
            "updated_at": RepositoryCoding.string(from: now)
        ]])
    }

    func invalidateDetails(for identifier: MediaIdentifier) async throws {
        db.execute(
            "UPDATE media_details_cache SET metadata_expires_at = ? WHERE tmdb_id = ? AND media_type = ?",
            parameters: [RepositoryCoding.string(from: .distantPast), identifier.id, identifier.mediaType.rawValue]
        )
    }

    func invalidateAvailability(for identifier: MediaIdentifier, region: String) async throws {
        db.execute(
            "UPDATE media_availability SET expires_at = ? WHERE tmdb_id = ? AND media_type = ? AND region = ?",
            parameters: [RepositoryCoding.string(from: .distantPast), identifier.id, identifier.mediaType.rawValue, region]
        )
    }

    private func cachedDetails(for identifier: MediaIdentifier) async throws -> CachedDetails? {
        let rows = try await db.queryRaw("""
            SELECT * FROM media_details_cache
            WHERE tmdb_id = ? AND media_type = ? AND deleted_at IS NULL
            LIMIT 1
        """, parameters: [identifier.id, identifier.mediaType.rawValue])
        guard let row = rows.first,
              let title = row["title"] as? String else {
            return nil
        }

        let snapshot: MediaDetailsSnapshot
        switch identifier.mediaType {
        case .movie:
            snapshot = .movie(Movie(
                id: identifier.id,
                title: title,
                overview: row["overview"] as? String ?? "",
                posterPath: row["poster_path"] as? String,
                backdropPath: row["backdrop_path"] as? String,
                releaseDate: nil,
                voteAverage: 0,
                voteCount: 0,
                genreIds: nil,
                genres: nil,
                adult: false,
                originalLanguage: "en",
                popularity: 0,
                runtime: nil,
                status: nil,
                tagline: nil,
                productionCountries: nil,
                imdbId: nil
            ))
        case .tv:
            snapshot = .tvShow(TVShow(
                id: identifier.id,
                name: title,
                overview: row["overview"] as? String ?? "",
                posterPath: row["poster_path"] as? String,
                backdropPath: row["backdrop_path"] as? String,
                firstAirDate: nil,
                voteAverage: 0,
                voteCount: 0,
                genreIds: nil,
                genres: nil,
                originalLanguage: "en",
                popularity: 0,
                status: nil,
                tagline: nil,
                productionCountries: nil,
                imdbId: nil
            ))
        }

        let expiresAt = RepositoryCoding.date(from: row["metadata_expires_at"])
            ?? RepositoryCoding.date(from: row["expires_at"])
            ?? .distantPast
        return CachedDetails(snapshot: snapshot, expiresAt: expiresAt)
    }

    private func cachedAvailability(for identifier: MediaIdentifier, region: String) async throws -> MediaAvailabilitySnapshot? {
        let rows = try await db.queryRaw("""
            SELECT * FROM media_availability
            WHERE tmdb_id = ? AND media_type = ? AND region = ? AND deleted_at IS NULL
            LIMIT 1
        """, parameters: [identifier.id, identifier.mediaType.rawValue, region])
        guard let row = rows.first,
              let providersJSON = row["providers_json"] as? String,
              let cachedAt = RepositoryCoding.date(from: row["cached_at"]),
              let expiresAt = RepositoryCoding.date(from: row["expires_at"]) else {
            return nil
        }

        return MediaAvailabilitySnapshot(
            identifier: identifier,
            region: region,
            providers: try RepositoryCoding.decode(WatchProvider.self, from: providersJSON),
            cachedAt: cachedAt,
            expiresAt: expiresAt
        )
    }

    private func mediaDetailsRow(
        identifier: MediaIdentifier,
        title: String,
        overview: String,
        posterPath: String?,
        backdropPath: String?,
        cachedAt: Date,
        metadataExpiresAt: Date
    ) -> [String: Any] {
        [
            "tmdb_id": identifier.id,
            "media_type": identifier.mediaType.rawValue,
            "title": title,
            "overview": overview,
            "poster_path": posterPath ?? NSNull(),
            "backdrop_path": backdropPath ?? NSNull(),
            "cached_at": RepositoryCoding.string(from: cachedAt),
            "expires_at": RepositoryCoding.string(from: metadataExpiresAt),
            "metadata_expires_at": RepositoryCoding.string(from: metadataExpiresAt),
            "availability_expires_at": RepositoryCoding.string(from: cachedAt)
        ]
    }
}

private struct CachedDetails {
    let snapshot: MediaDetailsSnapshot
    let expiresAt: Date

    var isFresh: Bool {
        expiresAt > Date()
    }
}
