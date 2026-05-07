import Foundation

protocol DiscoveryRepositoryProtocol: Sendable {
    /// Cache-first: emits SQLite-cached carousels immediately, then network-refreshed if stale.
    func observeCarousels(
        userId: String?,
        profile: UserProfile,
        filters: GlobalDiscoveryFilters,
        forceRefresh: Bool
    ) -> AsyncStream<[PersonalizedCarousel]>
}
