import Foundation

/// Cache-first discovery carousels. Emits SQLite snapshot immediately, then TMDB-refreshed if stale/new day.
@MainActor
final class LiveDiscoveryRepository: DiscoveryRepositoryProtocol {
    static let shared = LiveDiscoveryRepository()
    private let service = DiscoveryPersonalizationService.shared
    private let warmFeed = DiscoveryWarmFeedService.shared
    private init() {}

    nonisolated func observeCarousels(
        userId: String?,
        profile: UserProfile,
        filters: GlobalDiscoveryFilters,
        forceRefresh: Bool
    ) -> AsyncStream<[PersonalizedCarousel]> {
        AsyncStream { continuation in
            Task { @MainActor in
                if !forceRefresh {
                    let baseline = self.warmFeed.loadBaselineCarousels()
                    if !baseline.isEmpty {
                        continuation.yield(baseline)
                    }
                }

                // 1. Emit cache immediately if available
                if !forceRefresh, let cached = await self.service.loadCachedCarouselsIfAvailable(userId: userId) {
                    continuation.yield(cached)
                }
                // 2. Generate/refresh (uses L1 memory → L2 SQLite → L3 TMDB internally)
                if let carousels = try? await self.service.generatePersonalizedCarousels(
                    userProfile: profile,
                    filters: filters,
                    forceRefresh: forceRefresh
                ) {
                    continuation.yield(carousels)
                }
                continuation.finish()
            }
        }
    }
}
