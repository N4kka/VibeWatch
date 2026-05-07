import XCTest
@testable import VibeWatchApp

@MainActor
final class WatchProviderLoadStateTests: XCTestCase {

    func testMovieDetailProviderStateStartsLoading() {
        let viewModel = MovieDetailViewModel(
            movieId: 550,
            mediaDetailRepository: FakeMediaDetailRepository(),
            providersRepository: FakeWatchProvidersRepository(emissions: [])
        )

        XCTAssertTrue(viewModel.watchProviderState.isLoading)
    }

    func testMovieDetailProviderEmissionTransitionsToAvailable() async {
        let providers = CountryProviders(flatrate: [Self.provider(name: "Netflix")], rent: nil, buy: nil, link: nil)
        let viewModel = MovieDetailViewModel(
            movieId: 550,
            mediaDetailRepository: FakeMediaDetailRepository(movie: Self.movie()),
            providersRepository: FakeWatchProvidersRepository(emissions: [providers])
        )

        await viewModel.loadMovieDetails()
        await waitForProviderState(on: viewModel) { state in
            if case .available = state { return true }
            return false
        }

        guard case .available(let loadedProviders) = viewModel.watchProviderState else {
            return XCTFail("Expected available provider state")
        }
        XCTAssertEqual(loadedProviders.flatrate?.first?.providerName, "Netflix")
    }

    func testMovieDetailNilProviderEmissionTransitionsToUnavailable() async {
        let viewModel = MovieDetailViewModel(
            movieId: 550,
            mediaDetailRepository: FakeMediaDetailRepository(movie: Self.movie()),
            providersRepository: FakeWatchProvidersRepository(emissions: [nil])
        )

        await viewModel.loadMovieDetails()
        await waitForProviderState(on: viewModel) { $0.isUnavailable }

        XCTAssertTrue(viewModel.watchProviderState.isUnavailable)
    }

    private func waitForProviderState(
        on viewModel: MovieDetailViewModel,
        timeout: TimeInterval = 1,
        predicate: (WatchProviderLoadState) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(viewModel.watchProviderState) { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for provider state", file: file, line: line)
    }

    private static func movie() -> Movie {
        Movie(
            id: 550,
            title: "Fight Club",
            overview: "",
            posterPath: nil,
            backdropPath: nil,
            releaseDate: "1999-10-15",
            voteAverage: 8.4,
            voteCount: 1,
            genreIds: nil,
            genres: nil,
            adult: false,
            originalLanguage: "en",
            popularity: 1,
            runtime: 139,
            status: nil,
            tagline: nil,
            productionCountries: nil,
            imdbId: "tt0137523"
        )
    }

    private static func provider(name: String) -> Provider {
        Provider(
            providerId: abs(name.hashValue),
            providerName: name,
            logoPath: "/\(name).png",
            displayPriority: 0,
            price: nil,
            quality: nil,
            presentationType: nil,
            externalLink: nil
        )
    }
}

private struct FakeWatchProvidersRepository: WatchProvidersRepositoryProtocol {
    let emissions: [CountryProviders?]

    func observeProviders(mediaId: Int, mediaType: MediaType, region: String) -> AsyncStream<CountryProviders?> {
        AsyncStream { continuation in
            for emission in emissions {
                continuation.yield(emission)
            }
            continuation.finish()
        }
    }

    func providers(mediaId: Int, mediaType: MediaType, region: String) async -> CountryProviders? {
        emissions.last ?? nil
    }
}

private struct FakeMediaDetailRepository: MediaDetailRepositoryProtocol {
    var movie: Movie?

    func observeMovie(id: Int) -> AsyncStream<CachedMovieDetail> {
        AsyncStream { continuation in
            if let movie {
                continuation.yield(
                    CachedMovieDetail(
                        movie: movie,
                        credits: nil,
                        videos: [],
                        watchProviders: nil,
                        similarMovies: []
                    )
                )
            }
            continuation.finish()
        }
    }

    func observeTVShow(id: Int) -> AsyncStream<CachedTVShowDetail> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
