import XCTest
@testable import VibeWatchApp

/// La ricerca si fermava alla prima pagina: venti risultati e nessun segno che ce ne fossero
/// altri. Questi test coprono l'accumulo (le pagine si sommano), il dedup (TMDB ripete gli stessi
/// titoli fra le pagine) e le due guardie che impediscono richieste inutili.
@MainActor
final class SearchPaginationTests: XCTestCase {

    private var tmdb: StubTMDBSearchService!
    private var viewModel: SearchViewModel!

    override func setUp() async throws {
        try await super.setUp()
        tmdb = StubTMDBSearchService()
        viewModel = SearchViewModel(
            tmdbService: tmdb,
            localSearch: EmptyLocalTitleSearch(),
            preferenceManager: .shared
        )
    }

    override func tearDown() async throws {
        viewModel = nil; tmdb = nil
        try await super.tearDown()
    }

    /// Fa la prima ricerca e attende che la pagina 1 sia in lista.
    private func cerca(_ query: String) async {
        viewModel.searchQuery = query
        viewModel.search()
        await attendi { !self.viewModel.searchResults.isEmpty && self.tmdb.pagineChieste.contains(1) }
    }

    func testLaSecondaPaginaSiAggiungeAllaPrima() async {
        tmdb.pages = [
            1: (results: [Self.result(id: 1, title: "Spider-Man"),
                          Self.result(id: 2, title: "Spider-Man 2")], totalPages: 2),
            2: (results: [Self.result(id: 3, title: "Spider-Man 3")], totalPages: 2)
        ]
        await cerca("spider")
        XCTAssertEqual(viewModel.searchResults.count, 2)

        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults.last!)
        await attendi { self.viewModel.searchResults.count == 3 }

        XCTAssertEqual(Set(viewModel.searchResults.map(\.id)), [1, 2, 3])
    }

    func testITitoliRipetutiNonSiDuplicano() async {
        tmdb.pages = [
            1: (results: [Self.result(id: 1, title: "Spider-Man")], totalPages: 2),
            // TMDB rimanda lo stesso titolo nella pagina dopo: senza dedup comparirebbe due volte
            // e `ForEach` avrebbe due elementi con lo stesso id.
            2: (results: [Self.result(id: 1, title: "Spider-Man"),
                          Self.result(id: 9, title: "Spider-Man Nuovo")], totalPages: 2)
        ]
        await cerca("spider")
        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults.last!)
        await attendi { self.viewModel.searchResults.count == 2 }

        XCTAssertEqual(viewModel.searchResults.map(\.id).sorted(), [1, 9])
    }

    func testAllUltimaPaginaNonSiChiedeAltro() async {
        tmdb.pages = [1: (results: [Self.result(id: 1, title: "Solo")], totalPages: 1)]
        await cerca("solo")

        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults.last!)
        await attendi { true }

        XCTAssertEqual(tmdb.pagineChieste, [1], "non c'è una pagina 2 da chiedere")
    }

    /// Solo gli ultimi cinque elementi innescano il caricamento: chiederlo a metà lista è banda
    /// buttata via.
    func testUnItemLontanoDallaFineNonInnescaIlCaricamento() async {
        let primaPagina = (1...20).map { Self.result(id: $0, title: "Titolo \($0)") }
        tmdb.pages = [
            1: (results: primaPagina, totalPages: 3),
            2: (results: [Self.result(id: 21, title: "Titolo 21")], totalPages: 3)
        ]
        await cerca("titolo")

        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults[0])
        await attendi { true }

        XCTAssertEqual(tmdb.pagineChieste, [1])
    }

    func testUnaNuovaRicercaAzzeraLaPaginazione() async {
        tmdb.pages = [
            1: (results: [Self.result(id: 1, title: "Alfa")], totalPages: 3),
            2: (results: [Self.result(id: 2, title: "Alfa due")], totalPages: 3)
        ]
        await cerca("alfa")
        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults.last!)
        await attendi { self.viewModel.searchResults.count == 2 }

        tmdb.pagineChieste.removeAll()
        tmdb.pages = [1: (results: [Self.result(id: 5, title: "Beta")], totalPages: 1)]
        await cerca("beta")

        XCTAssertEqual(viewModel.searchResults.map(\.id), [5],
                       "i risultati della ricerca precedente non restano in lista")
        XCTAssertEqual(tmdb.pagineChieste, [1])
    }

    func testIRisultatiArrivanoOrdinatiPerRilevanza() async {
        tmdb.pages = [1: (results: [
            Self.result(id: 1, title: "Il caso Arachnospidone", popularity: 5000, votes: 200_000),
            Self.result(id: 2, title: "Spid", popularity: 0.2, votes: 3)
        ], totalPages: 1)]
        await cerca("Spid")

        XCTAssertEqual(viewModel.searchResults.first?.id, 2,
                       "il match esatto sta in cima, anche se è meno popolare")
    }

    // MARK: - Aiutanti

    private static func result(
        id: Int, title: String, popularity: Double = 1, votes: Int = 10
    ) -> SearchResult {
        SearchResult(
            id: id, mediaType: "movie", title: title, name: nil, overview: nil,
            posterPath: nil, backdropPath: nil, releaseDate: nil, firstAirDate: nil,
            voteAverage: 7, voteCount: votes, popularity: popularity
        )
    }

    /// `search()` debouncia di 350 ms e lavora su un `Task`: qui si aspetta la condizione.
    private func attendi(
        timeout: TimeInterval = 5,
        _ condizione: @escaping () -> Bool
    ) async {
        let scadenza = Date().addingTimeInterval(timeout)
        while Date() < scadenza {
            if condizione() { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}

// MARK: - Doppi

private struct EmptyLocalTitleSearch: LocalTitleSearching {
    func search(matching query: String, limit: Int) async -> [SearchResult] { [] }
}

/// Risponde solo a `searchMulti`; tutto il resto non serve a questi test e fallisce se chiamato,
/// invece di restituire dati finti che nasconderebbero un errore.
private final class StubTMDBSearchService: TMDBServiceProtocol, @unchecked Sendable {
    struct Page {
        let results: [SearchResult]
        let totalPages: Int
    }

    var pages: [Int: (results: [SearchResult], totalPages: Int)] = [:]
    var pagineChieste: [Int] = []

    func searchMulti(query: String, page: Int) async throws -> TMDBMultiResponse {
        pagineChieste.append(page)
        let entry = pages[page] ?? (results: [], totalPages: page)
        return TMDBMultiResponse(
            page: page,
            results: entry.results,
            totalPages: entry.totalPages,
            totalResults: entry.results.count
        )
    }

    private func nonServe(_ funzione: String = #function) -> Never {
        fatalError("StubTMDBSearchService: \(funzione) non fa parte di questi test")
    }

    func getTrendingMovies(timeWindow: TimeWindow, page: Int) async throws -> TMDBResponse<Movie> {
        TMDBResponse(page: 1, results: [], totalPages: 1, totalResults: 0)
    }
    func getTrendingTVShows(timeWindow: TimeWindow, page: Int) async throws -> TMDBResponse<TVShow> {
        TMDBResponse(page: 1, results: [], totalPages: 1, totalResults: 0)
    }
    func getPopularMovies(page: Int) async throws -> TMDBResponse<Movie> { nonServe() }
    func getTopRatedMovies(page: Int) async throws -> TMDBResponse<Movie> { nonServe() }
    func discoverMovies(
        withGenre genreId: Int?, sortBy: String, page: Int, minRuntime: Int?, maxRuntime: Int?,
        minRating: Double?, maxRating: Double?, releaseDateGte: String?, releaseDateLte: String?,
        country: String?
    ) async throws -> TMDBResponse<Movie> { nonServe() }
    func searchMovies(query: String, page: Int) async throws -> TMDBResponse<Movie> { nonServe() }
    func getPopularTVShows(page: Int) async throws -> TMDBResponse<TVShow> { nonServe() }
    func getTopRatedTVShows(page: Int) async throws -> TMDBResponse<TVShow> { nonServe() }
    func discoverTVShows(
        withGenre genreId: Int?, sortBy: String, page: Int, minRating: Double?, maxRating: Double?,
        firstAirDateGte: String?, firstAirDateLte: String?, country: String?
    ) async throws -> TMDBResponse<TVShow> { nonServe() }
    func searchTVShows(query: String, page: Int) async throws -> TMDBResponse<TVShow> { nonServe() }
    func getMovieDetails(id: Int) async throws -> Movie { nonServe() }
    func getMovieCredits(id: Int) async throws -> Credits { nonServe() }
    func getMovieVideos(id: Int) async throws -> TMDBVideosResponse { nonServe() }
    func getSimilarMovies(id: Int, page: Int) async throws -> TMDBResponse<Movie> { nonServe() }
    func getTVShowDetails(id: Int) async throws -> TVShow { nonServe() }
    func getTVShowCredits(id: Int) async throws -> Credits { nonServe() }
    func getTVShowVideos(id: Int) async throws -> TMDBVideosResponse { nonServe() }
    func getSimilarTVShows(id: Int, page: Int) async throws -> TMDBResponse<TVShow> { nonServe() }
    func getTVSeasonDetails(showId: Int, seasonNumber: Int) async throws -> SeasonDetail { nonServe() }
    func getMovieExternalIds(id: Int) async throws -> ExternalIds { nonServe() }
    func getTVShowExternalIds(id: Int) async throws -> ExternalIds { nonServe() }
    func getPersonDetails(id: Int) async throws -> PersonDetails { nonServe() }
    func getPersonCombinedCredits(id: Int) async throws -> PersonCombinedCredits { nonServe() }
    func searchPerson(query: String) async throws -> [PersonSearchResult] { nonServe() }
    func getMovieWatchProviders(id: Int) async throws -> WatchProvider { nonServe() }
    func getTVShowWatchProviders(id: Int) async throws -> WatchProvider { nonServe() }
    func getAvailableWatchProviders(mediaType: String, region: String) async throws -> [Provider] { [] }
}
