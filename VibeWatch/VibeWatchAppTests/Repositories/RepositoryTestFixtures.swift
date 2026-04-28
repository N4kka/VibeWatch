@testable import VibeWatchApp

extension Movie {
    static func repositoryTestFixture(id: Int, title: String) -> Movie {
        Movie(
            id: id,
            title: title,
            overview: "Overview",
            posterPath: "/poster.jpg",
            backdropPath: "/backdrop.jpg",
            releaseDate: "2026-01-01",
            voteAverage: 8.2,
            voteCount: 42,
            genreIds: [18],
            genres: nil,
            adult: false,
            originalLanguage: "en",
            popularity: 10,
            runtime: 100,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }
}

extension TVShow {
    static func repositoryTestFixture(id: Int, name: String) -> TVShow {
        TVShow(
            id: id,
            name: name,
            overview: "Overview",
            posterPath: "/poster.jpg",
            backdropPath: "/backdrop.jpg",
            firstAirDate: "2026-01-01",
            voteAverage: 8.1,
            voteCount: 24,
            genreIds: [18],
            genres: nil,
            originalLanguage: "en",
            popularity: 9,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: nil
        )
    }
}
