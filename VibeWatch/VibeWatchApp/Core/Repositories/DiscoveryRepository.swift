import Foundation

struct DiscoveryCarouselSnapshot {
    let type: String
    let title: String
    let mediaType: MediaType?
    let position: Int
    let items: [Movie]
    let cachedAt: Date
    let expiresAt: Date
}

struct DiscoveryInteraction {
    let userId: String
    let identifier: MediaIdentifier
    let carouselType: String
    let interactionType: String
    let occurredAt: Date
}

@MainActor
protocol DiscoveryRepository: AnyObject, Sendable {
    func carousels(for userId: String, filters: GlobalDiscoveryFilters) -> AsyncStream<[DiscoveryCarouselSnapshot]>

    func refreshCarousels(for userId: String, filters: GlobalDiscoveryFilters) async throws
    func invalidateCarousels(for userId: String) async throws
    func recordInteraction(_ interaction: DiscoveryInteraction) async throws
}
