import Foundation

/// Cache-first media detail loader. Emits SQLite snapshot immediately, then refreshes from TMDB in background.
/// Providers are NOT included in this stream — use WatchProvidersRepositoryProtocol separately.
@MainActor
final class LiveMediaDetailRepository: MediaDetailRepositoryProtocol {
    static let shared = LiveMediaDetailRepository()
    private let detailCache = DetailCacheService.shared
    private let tmdb: any TMDBServiceProtocol = TMDBService.shared
    private init() {}

    nonisolated func observeMovie(id: Int) -> AsyncStream<CachedMovieDetail> {
        AsyncStream { continuation in
            Task { @MainActor in
                // 1. Emit from cache immediately if available
                if let cached = try? await self.detailCache.getCachedMovieDetails(movieId: id) {
                    continuation.yield(cached)
                    // Background network refresh
                    Task(priority: .utility) { @MainActor in
                        if let refreshed = try? await self.fetchMovie(id: id) {
                            try? await self.detailCache.cacheMovieDetails(
                                movie: refreshed.movie,
                                credits: refreshed.credits,
                                videos: refreshed.videos,
                                watchProviders: refreshed.watchProviders,
                                similarMovies: refreshed.similarMovies,
                                imdbId: refreshed.movie.imdbId
                            )
                            continuation.yield(refreshed)
                        }
                        continuation.finish()
                    }
                    return
                }
                // 2. Cache miss — fetch from network (spinner visible until this resolves)
                if let fresh = try? await self.fetchMovie(id: id) {
                    try? await self.detailCache.cacheMovieDetails(
                        movie: fresh.movie,
                        credits: fresh.credits,
                        videos: fresh.videos,
                        watchProviders: fresh.watchProviders,
                        similarMovies: fresh.similarMovies,
                        imdbId: fresh.movie.imdbId
                    )
                    continuation.yield(fresh)
                }
                continuation.finish()
            }
        }
    }

    nonisolated func observeTVShow(id: Int) -> AsyncStream<CachedTVShowDetail> {
        AsyncStream { continuation in
            Task { @MainActor in
                if let cached = try? await self.detailCache.getCachedTVShowDetails(tvShowId: id) {
                    continuation.yield(cached)
                    Task(priority: .utility) { @MainActor in
                        if let refreshed = try? await self.fetchTVShow(id: id) {
                            try? await self.detailCache.cacheTVShowDetails(
                                tvShow: refreshed.tvShow,
                                credits: refreshed.credits,
                                videos: refreshed.videos,
                                watchProviders: refreshed.watchProviders,
                                similarShows: refreshed.similarShows,
                                imdbId: refreshed.tvShow.imdbId
                            )
                            continuation.yield(refreshed)
                        }
                        continuation.finish()
                    }
                    return
                }
                if let fresh = try? await self.fetchTVShow(id: id) {
                    try? await self.detailCache.cacheTVShowDetails(
                        tvShow: fresh.tvShow,
                        credits: fresh.credits,
                        videos: fresh.videos,
                        watchProviders: fresh.watchProviders,
                        similarShows: fresh.similarShows,
                        imdbId: fresh.tvShow.imdbId
                    )
                    continuation.yield(fresh)
                }
                continuation.finish()
            }
        }
    }

    private func fetchMovie(id: Int) async throws -> CachedMovieDetail {
        async let movieTask = tmdb.getMovieDetails(id: id)
        async let creditsTask = tmdb.getMovieCredits(id: id)
        async let videosTask = tmdb.getMovieVideos(id: id)
        async let similarTask = tmdb.getSimilarMovies(id: id, page: 1)
        let (movie, credits, videosResp, similar) = try await (movieTask, creditsTask, videosTask, similarTask)
        // movie.imdbId is decoded directly from TMDB /movie/{id} response (imdb_id field)
        let trailers = videosResp.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
        return CachedMovieDetail(
            movie: movie,
            credits: credits,
            videos: trailers,
            watchProviders: nil,
            similarMovies: Array(similar.results.prefix(10))
        )
    }

    private func fetchTVShow(id: Int) async throws -> CachedTVShowDetail {
        async let tvTask = tmdb.getTVShowDetails(id: id)
        async let creditsTask = tmdb.getTVShowCredits(id: id)
        async let videosTask = tmdb.getTVShowVideos(id: id)
        async let similarTask = tmdb.getSimilarTVShows(id: id, page: 1)
        let (tvShow, credits, videosResp, similar) = try await (tvTask, creditsTask, videosTask, similarTask)
        let trailers = videosResp.results.filter { $0.type == "Trailer" && $0.site == "YouTube" }
        return CachedTVShowDetail(
            tvShow: tvShow,
            credits: credits,
            videos: trailers,
            watchProviders: nil,
            similarShows: Array(similar.results.prefix(10))
        )
    }
}
