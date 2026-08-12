import XCTest
@testable import VibeWatchApp

@MainActor
final class WatchProvidersRepositoryTests: XCTestCase {

    func testStreamingAvailabilityFailureFallsBackToTMDBProviders() async {
        let tmdbProviders = CountryProviders(flatrate: [Self.provider(name: "Netflix", logoPath: "/netflix.png")], rent: nil, buy: nil, link: "https://justwatch.example/movie")
        let repository = LiveWatchProvidersRepository(
            local: EmptyWatchProvidersCache(),
            tmdb: FakeTMDBWatchProvidersService(movieProviders: WatchProvider(results: ["US": tmdbProviders])),
            streaming: FakeStreamingAvailabilityProvider(result: .failure(TestError.expected))
        )

        let result = await repository.providers(mediaId: 550, mediaType: .movie, region: "US")

        XCTAssertEqual(result?.flatrate?.first?.providerName, "Netflix")
        XCTAssertEqual(result?.link, "https://justwatch.example/movie")
    }

    func testStreamingAvailabilityProvidersMergeWithTMDBLogoAndLinkData() async {
        let streamingProviders = CountryProviders(
            flatrate: [
                Self.provider(name: "Netflix", logoPath: "https://cdn.example/netflix.svg", externalLink: URL(string: "https://stream.example/netflix"))
            ],
            rent: nil,
            buy: nil,
            link: nil
        )
        let tmdbProviders = CountryProviders(
            flatrate: [Self.provider(name: "Netflix", logoPath: "/netflix.png")],
            rent: [Self.provider(name: "Apple TV", logoPath: "/apple.png")],
            buy: nil,
            link: "https://justwatch.example/merged"
        )
        let repository = LiveWatchProvidersRepository(
            local: EmptyWatchProvidersCache(),
            tmdb: FakeTMDBWatchProvidersService(movieProviders: WatchProvider(results: ["US": tmdbProviders])),
            streaming: FakeStreamingAvailabilityProvider(result: .success(streamingProviders))
        )

        let result = await repository.providers(mediaId: 550, mediaType: .movie, region: "US")

        XCTAssertEqual(result?.flatrate?.first?.providerName, "Netflix")
        XCTAssertEqual(result?.flatrate?.first?.logoPath, "/netflix.png")
        XCTAssertEqual(result?.flatrate?.first?.externalLink, URL(string: "https://stream.example/netflix"))
        XCTAssertEqual(result?.rent?.first?.providerName, "Apple TV")
        XCTAssertEqual(result?.link, "https://justwatch.example/merged")
    }

    func testBothSourcesUnavailableReturnsNil() async {
        let repository = LiveWatchProvidersRepository(
            local: EmptyWatchProvidersCache(),
            tmdb: FakeTMDBWatchProvidersService(movieProviders: WatchProvider(results: [:])),
            streaming: FakeStreamingAvailabilityProvider(result: .success(CountryProviders(flatrate: nil, rent: nil, buy: nil, link: nil)))
        )

        let result = await repository.providers(mediaId: 550, mediaType: .movie, region: "US")

        XCTAssertNil(result)
    }

    private static func provider(
        name: String,
        logoPath: String,
        externalLink: URL? = nil
    ) -> Provider {
        Provider(
            providerId: abs(name.hashValue),
            providerName: name,
            logoPath: logoPath,
            displayPriority: 0,
            price: nil,
            quality: nil,
            presentationType: nil,
            externalLink: externalLink
        )
    }
}

private enum TestError: Error {
    case expected
}

private struct EmptyWatchProvidersCache: WatchProvidersCache {
    func cachedProviders(mediaId: Int, mediaType: MediaType, region: String) async -> CountryProviders? {
        nil
    }

    func save(_ providers: CountryProviders, mediaId: Int, mediaType: MediaType, region: String) async {}
}

private struct FakeTMDBWatchProvidersService: TMDBWatchProvidersServiceProtocol {
    var movieProviders = WatchProvider(results: [:])
    var tvProviders = WatchProvider(results: [:])

    func getMovieWatchProviders(id: Int) async throws -> WatchProvider {
        movieProviders
    }

    func getTVShowWatchProviders(id: Int) async throws -> WatchProvider {
        tvProviders
    }

    /// Il doppio non parla con la rete: l'elenco per regione qui non serve a nessun test.
    func getAvailableWatchProviders(mediaType: String, region: String) async throws -> [Provider] {
        []
    }
}

private struct FakeStreamingAvailabilityProvider: StreamingAvailabilityProviding {
    let result: Result<CountryProviders, Error>

    func getProviders(tmdbId: Int, type: MediaType, region: String) async throws -> CountryProviders {
        try result.get()
    }
}
