import XCTest
@testable import VibeWatchApp

@MainActor
final class LiveDiscoveryRepositoryTests: XCTestCase {
    private let db = SQLiteService.shared

    func testRefreshStoresChooseForYouCarouselAtFirstPosition() async throws {
        let userId = "repository-discovery-\(UUID().uuidString)"
        db.execute("DELETE FROM discovery_carousel_items WHERE carousel_id LIKE ?", parameters: ["\(userId)%"])
        try await db.delete("discovery_carousels", where: "user_id = ?", parameters: [userId], hard: true)

        let repository = LiveDiscoveryRepository(
            db: db,
            carouselProvider: { _, _ in
                [
                    DiscoveryCarouselSnapshot(
                        type: "trending",
                        title: "Trending",
                        mediaType: .movie,
                        position: 0,
                        items: [Movie.repositoryTestFixture(id: 8_910_001, title: "Trending Movie")],
                        cachedAt: Date(),
                        expiresAt: Date().addingTimeInterval(3600)
                    ),
                    DiscoveryCarouselSnapshot(
                        type: "choose_for_you",
                        title: "Choose for You",
                        mediaType: .movie,
                        position: 1,
                        items: [Movie.repositoryTestFixture(id: 8_910_002, title: "Chosen Movie")],
                        cachedAt: Date(),
                        expiresAt: Date().addingTimeInterval(3600)
                    )
                ]
            }
        )

        try await repository.refreshCarousels(for: userId, filters: GlobalDiscoveryFilters())

        var emitted: [DiscoveryCarouselSnapshot] = []
        for await snapshot in repository.carousels(for: userId, filters: GlobalDiscoveryFilters()) {
            emitted = snapshot
            break
        }

        XCTAssertEqual(emitted.first?.type, "choose_for_you")
        XCTAssertEqual(emitted.map(\.position), [0, 1])
    }
}
