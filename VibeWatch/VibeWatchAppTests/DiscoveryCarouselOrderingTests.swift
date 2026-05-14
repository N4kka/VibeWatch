import XCTest
@testable import VibeWatchApp

@MainActor
final class DiscoveryCarouselOrderingTests: XCTestCase {

    func testDailyMixCarouselIsPrioritizedFirstWhenPresent() {
        let carousels = [
            Self.carousel(type: .hotThisWeek, title: "Hot This Week"),
            Self.carousel(type: .dailyMix, title: "Choose for you"),
            Self.carousel(type: .staffPicks, title: "Staff Picks")
        ]

        let ordered = DiscoveryViewModel.prioritizeCarouselOrder(carousels)

        XCTAssertEqual(ordered.map(\.type), [.dailyMix, .hotThisWeek, .staffPicks])
    }

    private static func carousel(type: CarouselType, title: String) -> PersonalizedCarousel {
        PersonalizedCarousel(
            type: type,
            title: title,
            items: [movie(id: abs(type.rawValue.hashValue))],
            descriptions: [:],
            reason: ""
        )
    }

    private static func movie(id: Int) -> Movie {
        Movie(
            id: id,
            title: "Movie \(id)",
            overview: "",
            posterPath: nil,
            backdropPath: nil,
            releaseDate: "2026-01-01",
            voteAverage: 7,
            voteCount: 1,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "en",
            popularity: 1,
            runtime: 100,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }
}
