import XCTest
@testable import VibeWatchApp

@MainActor
final class DiscoveryViewModelRepositoryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "GlobalDiscoveryFilters")
        UserDefaults.standard.removeObject(forKey: "discovery_last_loaded_day_anonymous")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "GlobalDiscoveryFilters")
        UserDefaults.standard.removeObject(forKey: "discovery_last_loaded_day_anonymous")
        super.tearDown()
    }

    func testLoadContentPopulatesCarouselsFromRepositorySnapshots() async {
        let repository = MockDiscoveryRepository()
        let movie = Movie.repositoryTestFixture(id: 42, title: "Repository Discovery Movie")
        repository.carouselsByUser["anonymous"] = [
            DiscoveryCarouselSnapshot(
                type: CarouselType.dailyMix.rawValue,
                title: "Daily repository picks",
                mediaType: .movie,
                position: 0,
                items: [movie],
                cachedAt: Date(),
                expiresAt: Date().addingTimeInterval(3600)
            )
        ]
        let viewModel = DiscoveryViewModel(repository: repository, userId: "anonymous")

        await viewModel.loadContent(forceRefresh: false)

        XCTAssertEqual(viewModel.personalizedCarousels.count, 1)
        XCTAssertEqual(viewModel.personalizedCarousels.first?.type, .dailyMix)
        XCTAssertEqual(viewModel.personalizedCarousels.first?.title, "Daily repository picks")
        XCTAssertEqual(viewModel.personalizedCarousels.first?.items.first?.title, "Repository Discovery Movie")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertNil(viewModel.error)
    }
}
