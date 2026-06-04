import Foundation

/// Stale-while-revalidate discovery carousels.
/// Always emits any cached data (stale or fresh) immediately for instant paint, then
/// regenerates from TMDB in the background when the cache is expired or a force-refresh
/// is requested. The stream yields twice on a cache-miss day: once with stale data, once
/// with fresh data. Callers animate the second emission.
@MainActor
final class LiveDiscoveryRepository: DiscoveryRepositoryProtocol {
    static let shared = LiveDiscoveryRepository()
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
                // Emission 1: any cached data, stale or fresh — instant paint
                let anyCache = await self.service.loadAnyCachedCarouselsIfAvailable(userId: userId)
                if let anyCache {
                    continuation.yield(anyCache)
                }

                // Refresh when: explicit force, no cache at all, or cache is past expiry
                let shouldRefresh: Bool
                if forceRefresh || anyCache == nil {
                    shouldRefresh = true
                } else {
                    shouldRefresh = await self.service.isCacheStale(userId: userId)
                }

                if shouldRefresh {
                    // Emission 2: fresh data from TMDB — caller animates the swap
                    if let fresh = try? await self.service.generatePersonalizedCarousels(
                        userProfile: profile,
                        filters: filters,
                        forceRefresh: true
                    ) {
                        continuation.yield(fresh)
                    }
                }

                continuation.finish()
            }
        }
    }
}
