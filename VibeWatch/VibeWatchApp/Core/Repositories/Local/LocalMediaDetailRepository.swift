import Foundation

/// Reads cached movie/TV-show detail from `detail_cache`. Never touches the network.
@MainActor
final class LocalMediaDetailRepository: MediaDetailRepositoryProtocol {
    static let shared = LocalMediaDetailRepository()
    private let cache = DetailCacheService.shared
    private init() {}

    nonisolated func observeMovie(id: Int) -> AsyncStream<CachedMovieDetail> {
        AsyncStream { continuation in
            Task { @MainActor in
                if let cached = try? await self.cache.getCachedMovieDetails(movieId: id) {
                    continuation.yield(cached)
                }
                continuation.finish()
            }
        }
    }

    nonisolated func observeTVShow(id: Int) -> AsyncStream<CachedTVShowDetail> {
        AsyncStream { continuation in
            Task { @MainActor in
                if let cached = try? await self.cache.getCachedTVShowDetails(tvShowId: id) {
                    continuation.yield(cached)
                }
                continuation.finish()
            }
        }
    }
}
