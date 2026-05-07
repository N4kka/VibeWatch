import Foundation

protocol MediaDetailRepositoryProtocol: Sendable {
    /// Cache-first: emits cached snapshot immediately, then refreshed data after background network fetch.
    func observeMovie(id: Int) -> AsyncStream<CachedMovieDetail>
    func observeTVShow(id: Int) -> AsyncStream<CachedTVShowDetail>
}
