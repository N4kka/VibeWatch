import Foundation

@MainActor
final class DiscoveryWarmFeedService {
    static let shared = DiscoveryWarmFeedService()
    private init() {}

    func loadBaselineCarousels() -> [PersonalizedCarousel] {
        guard let url = Bundle.main.url(forResource: "discovery_warm_baseline", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WarmCarouselPayload].self, from: data) else {
            return []
        }

        return decoded.compactMap { payload in
            guard let type = CarouselType(rawValue: payload.type), !payload.items.isEmpty else { return nil }
            return PersonalizedCarousel(
                type: type,
                title: payload.title,
                items: payload.items,
                descriptions: [:],
                reason: payload.reason
            )
        }
    }
}

private struct WarmCarouselPayload: Decodable {
    let type: String
    let title: String
    let reason: String
    let items: [Movie]
}
