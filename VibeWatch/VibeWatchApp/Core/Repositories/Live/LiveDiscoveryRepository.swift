import Foundation

/// Cache-first discovery carousels. Emits SQLite snapshot immediately on same-day launches.
/// On first install or cache expiry, generates fresh content from TMDB (caller shows a spinner meanwhile).
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
                if !forceRefresh {
                    // Same-day path: SQLite cache is fresh — paint instantly, done.
                    if let cached = await self.service.loadCachedCarouselsIfAvailable(userId: userId) {
                        continuation.yield(cached)
                        continuation.finish()
                        return
                    }
                }
                // No valid cache (first install or new day) — generate from TMDB.
                // The view shows a spinner while this runs.
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
