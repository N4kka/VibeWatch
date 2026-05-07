import Foundation

protocol WatchProvidersRepositoryProtocol: Sendable {
    /// Emits cached providers immediately (if fresh), then refreshed providers after network fetch (if stale/absent).
    func observeProviders(mediaId: Int, mediaType: MediaType, region: String) -> AsyncStream<CountryProviders?>
    /// Direct async fetch — returns cached if fresh, fetches from network if stale/absent.
    func providers(mediaId: Int, mediaType: MediaType, region: String) async -> CountryProviders?
}
