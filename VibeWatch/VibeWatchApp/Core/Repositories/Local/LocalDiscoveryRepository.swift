import Foundation

/// Reads cached discovery carousels from `personalized_discovery`. Never touches the network.
@MainActor
final class LocalDiscoveryRepository: DiscoveryRepositoryProtocol {
    static let shared = LocalDiscoveryRepository()
    private let service = DiscoveryPersonalizationService.shared
    private init() {}

    nonisolated func observeCarousels(
        userId: String?,
        profile: UserProfile,
        filters: GlobalDiscoveryFilters,
        forceRefresh: Bool
    ) -> AsyncStream<[PersonalizedCarousel]> {
        AsyncStream { continuation in
            Task { @MainActor in
                if let cached = await self.service.loadCachedCarouselsIfAvailable(userId: userId) {
                    continuation.yield(cached)
                }
                continuation.finish()
            }
        }
    }
}
