import XCTest
@testable import VibeWatchApp

final class MediaListItemTests: XCTestCase {
    func testMovieConversionPreservesOverviewForSeenListTransfer() {
        let item = MediaListItem(
            mediaId: 42,
            mediaType: .movie,
            title: "Arrival",
            posterPath: "/arrival.jpg",
            runtime: 116,
            voteAverage: 7.6,
            voteCount: 1234,
            releaseDate: "2016-11-11",
            genres: [18, 878],
            overview: "A linguist works with the military to communicate with alien visitors."
        )

        let movie = item.asMovie()

        XCTAssertEqual(movie.overview, item.overview)
        XCTAssertEqual(movie.title, item.title)
        XCTAssertEqual(movie.posterPath, item.posterPath)
        XCTAssertEqual(movie.runtime, item.runtime)
        XCTAssertEqual(movie.voteAverage, item.voteAverage)
        XCTAssertEqual(movie.voteCount, item.voteCount)
        XCTAssertEqual(movie.releaseDate, item.releaseDate)
        XCTAssertEqual(movie.genreIds, item.genres)
    }

    func testDisplayOverviewUsesFetchedFallbackWhenCachedOverviewIsMissing() {
        let item = MediaListItem(
            mediaId: 326,
            mediaType: .movie,
            title: "Snatch",
            posterPath: "/snatch.jpg",
            overview: ""
        )

        XCTAssertEqual(item.displayOverview(fallback: "A diamond heist goes sideways."), "A diamond heist goes sideways.")
    }

    func testDisplayOverviewPrefersCachedOverview() {
        let item = MediaListItem(
            mediaId: 447,
            mediaType: .movie,
            title: "After Life",
            posterPath: "/after-life.jpg",
            overview: "Cached list overview."
        )

        XCTAssertEqual(item.displayOverview(fallback: "Fetched detail overview."), "Cached list overview.")
    }

    func testSubtitleForTVShowIncludesSeasonsYearRatingAndDuration() {
        let item = MediaListItem(
            mediaId: 79410,
            mediaType: .tv,
            title: "After Life",
            posterPath: "/after-life.jpg",
            voteAverage: 7.8,
            releaseDate: "2019-03-08"
        )

        XCTAssertEqual(item.subtitle(seasonCount: 3, duration: 30), "3 seasons | 2019 | 7.8 | 30m")
    }

    func testSubtitleForMovieIncludesYearRatingAndDuration() {
        let item = MediaListItem(
            mediaId: 550,
            mediaType: .movie,
            title: "Fight Club",
            posterPath: "/fight-club.jpg",
            runtime: 139,
            voteAverage: 8.4,
            releaseDate: "1999-10-15"
        )

        XCTAssertEqual(item.subtitle(), "1999 | 8.4 | 2h 19m")
    }

    func testSubtitleComponentsMarkRatingForStarDisplay() {
        let item = MediaListItem(
            mediaId: 550,
            mediaType: .movie,
            title: "Fight Club",
            posterPath: "/fight-club.jpg",
            runtime: 139,
            voteAverage: 8.4,
            releaseDate: "1999-10-15"
        )

        let components = item.subtitleComponents()

        XCTAssertEqual(components.map(\.text), ["1999", "8.4", "2h 19m"])
        XCTAssertEqual(components.map(\.showsRatingStar), [false, true, false])
    }
}
