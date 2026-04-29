import XCTest
@testable import VibeWatchApp

@MainActor
final class DetailViewModelRepositoryTests: XCTestCase {
    func testMovieDetailViewModelLoadsMovieSnapshotFromRepository() async {
        let repository = MockMediaRepository()
        repository.detailsByIdentifier[MediaIdentifier(id: 42, mediaType: .movie)] = .movie(
            Movie.detailRepositoryTestFixture(id: 42, title: "Repository Movie")
        )
        let viewModel = MovieDetailViewModel(
            movieId: 42,
            mediaRepository: repository,
            loadSupplementalInBackground: false
        )

        await viewModel.loadMovieDetails()

        XCTAssertEqual(viewModel.movie?.title, "Repository Movie")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
    }

    func testTVShowDetailViewModelLoadsShowSnapshotFromRepository() async {
        let repository = MockMediaRepository()
        repository.detailsByIdentifier[MediaIdentifier(id: 84, mediaType: .tv)] = .tvShow(
            TVShow.detailRepositoryTestFixture(id: 84, name: "Repository Show")
        )
        let viewModel = TVShowDetailViewModel(
            tvShowId: 84,
            mediaRepository: repository,
            loadSupplementalInBackground: false
        )

        await viewModel.loadTVShowDetails()

        XCTAssertEqual(viewModel.tvShow?.name, "Repository Show")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
    }
}

private extension Movie {
    static func detailRepositoryTestFixture(id: Int, title: String) -> Movie {
        Movie(
            id: id,
            title: title,
            overview: "Overview",
            posterPath: "/poster.jpg",
            backdropPath: "/backdrop.jpg",
            releaseDate: "2020-01-01",
            voteAverage: 8.0,
            voteCount: 100,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "en",
            popularity: 10,
            runtime: 120,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: "tt0000042"
        )
    }
}

private extension TVShow {
    static func detailRepositoryTestFixture(id: Int, name: String) -> TVShow {
        TVShow(
            id: id,
            name: name,
            overview: "Overview",
            posterPath: "/poster.jpg",
            backdropPath: "/backdrop.jpg",
            firstAirDate: "2021-01-01",
            voteAverage: 8.5,
            voteCount: 200,
            genreIds: nil,
            genres: nil,
            originalLanguage: "en",
            popularity: 12,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: "tt0000084"
        )
    }
}
