import Foundation

@MainActor
final class MockDiscoveryRepository: DiscoveryRepository {
    var carouselsByUser: [String: [DiscoveryCarouselSnapshot]] = [:]
    var recordedInteractions: [DiscoveryInteraction] = []

    func carousels(for userId: String, filters: GlobalDiscoveryFilters) -> AsyncStream<[DiscoveryCarouselSnapshot]> {
        AsyncStream { continuation in
            continuation.yield(carouselsByUser[userId] ?? [])
            continuation.finish()
        }
    }

    func refreshCarousels(for userId: String, filters: GlobalDiscoveryFilters) async throws {}

    func invalidateCarousels(for userId: String) async throws {
        carouselsByUser.removeValue(forKey: userId)
    }

    func recordInteraction(_ interaction: DiscoveryInteraction) async throws {
        recordedInteractions.append(interaction)
    }
}
