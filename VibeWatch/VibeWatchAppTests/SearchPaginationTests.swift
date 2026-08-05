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

    /// Fa una ricerca e attende che in lista ci siano **esattamente** i risultati attesi.
    ///
    /// Prima aspettava `!searchResults.isEmpty && pagineChieste.contains(1)`, che dalla SECONDA
    /// ricerca in poi è già vero appena parte: la lista è ancora piena dei risultati precedenti,
    /// quindi l'attesa finiva nell'istante in cui la pagina 1 veniva *chiesta*, prima che i nuovi
    /// risultati la sostituissero. È così che `testUnaNuovaRicercaAzzeraLaPaginazione` falliva
    /// circa una volta su sei leggendo `[1, 2]` invece di `[5]` — e il difetto era nell'attesa,
    /// non nel codice sotto esame.
    ///
    /// Aspettare l'insieme esatto vale anche al contrario: se la ricerca nuova NON azzerasse la
    /// lista, qui si arriverebbe al timeout con scritto cosa mancava.
    private func cerca(
        _ query: String, attesi: Set<Int>,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        viewModel.searchQuery = query
        viewModel.search()
        await attendi("i risultati di \"\(query)\": \(attesi.sorted())", file: file, line: line) {
            Set(self.viewModel.searchResults.map(\.id)) == attesi
        }
    }

    func testLaSecondaPaginaSiAggiungeAllaPrima() async {
        tmdb.pages = [
            1: (results: [Self.result(id: 1, title: "Spider-Man"),
                          Self.result(id: 2, title: "Spider-Man 2")], totalPages: 2),
            2: (results: [Self.result(id: 3, title: "Spider-Man 3")], totalPages: 2)
        ]
        await cerca("spider", attesi: [1, 2])

        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults.last!)
        await attendi("la pagina 2 in coda alla 1") { self.viewModel.searchResults.count == 3 }

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
        await cerca("spider", attesi: [1])
        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults.last!)
        await attendi("la pagina 2, deduplicata") { self.viewModel.searchResults.count == 2 }

        XCTAssertEqual(viewModel.searchResults.map(\.id).sorted(), [1, 9])
    }

    func testAllUltimaPaginaNonSiChiedeAltro() async {
        tmdb.pages = [1: (results: [Self.result(id: 1, title: "Solo")], totalPages: 1)]
        await cerca("solo", attesi: [1])

        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults.last!)
        await nonDeveSuccedereNiente()

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
        await cerca("titolo", attesi: Set(1...20))

        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults[0])
        await nonDeveSuccedereNiente()

        XCTAssertEqual(tmdb.pagineChieste, [1])
    }

    func testUnaNuovaRicercaAzzeraLaPaginazione() async {
        tmdb.pages = [
            1: (results: [Self.result(id: 1, title: "Alfa")], totalPages: 3),
            2: (results: [Self.result(id: 2, title: "Alfa due")], totalPages: 3)
        ]
        await cerca("alfa", attesi: [1])
        viewModel.loadMoreIfNeeded(currentItem: viewModel.searchResults.last!)
        await attendi("la pagina 2 di \"alfa\"") { self.viewModel.searchResults.count == 2 }

        tmdb.pagineChieste.removeAll()
        tmdb.pages = [1: (results: [Self.result(id: 5, title: "Beta")], totalPages: 1)]
        await cerca("beta", attesi: [5])

        XCTAssertEqual(viewModel.searchResults.map(\.id), [5],
                       "i risultati della ricerca precedente non restano in lista")
        XCTAssertEqual(tmdb.pagineChieste, [1])
    }

    func testIRisultatiArrivanoOrdinatiPerRilevanza() async {
        tmdb.pages = [1: (results: [
            Self.result(id: 1, title: "Il caso Arachnospidone", popularity: 5000, votes: 200_000),
            Self.result(id: 2, title: "Spid", popularity: 0.2, votes: 3)
        ], totalPages: 1)]
        await cerca("Spid", attesi: [1, 2])

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
    ///
    /// Allo scadere **fa fallire il test**. Prima usciva in silenzio, quindi un caricamento che
    /// non arrivava mai non si presentava come un timeout ma come un'asserzione incomprensibile
    /// venti righe più giù, senza dire cosa si stava aspettando.
    private func attendi(
        _ cosa: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line,
        _ condizione: @escaping () -> Bool
    ) async {
        let scadenza = Date().addingTimeInterval(timeout)
        while Date() < scadenza {
            if condizione() { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("timeout dopo \(timeout)s aspettando \(cosa)", file: file, line: line)
    }

    /// Per le asserzioni negative: dà a una richiesta indesiderata il tempo di farsi vedere.
    ///
    /// I due test che vietano una pagina 2 usavano `attendi { true }`, che torna all'istante e
    /// non aspetta niente: una richiesta partita anche solo un tick dopo sarebbe sfuggita a
    /// entrambi, e il test sarebbe passato senza aver verificato nulla.
    private func nonDeveSuccedereNiente(entro: TimeInterval = 0.5) async {
        try? await Task.sleep(nanoseconds: UInt64(entro * 1_000_000_000))
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

    /// `searchMulti` la chiama il `Task` del view model, che non gira sul main actor; il test
    /// invece legge e scrive dal main actor. Senza lock sono due thread sullo stesso `Array`: un
    /// data race vero, di quelli che il Thread Sanitizer segnala e che ogni tanto fanno leggere
    /// un array a metà aggiornamento. Il `@unchecked Sendable` qui sopra dichiarava una sicurezza
    /// che non c'era.
    private let lock = NSLock()
    private var _pages: [Int: (results: [SearchResult], totalPages: Int)] = [:]
    private var _pagineChieste: [Int] = []

    var pages: [Int: (results: [SearchResult], totalPages: Int)] {
        get { lock.withLock { _pages } }
        set { lock.withLock { _pages = newValue } }
    }

    var pagineChieste: [Int] {
        get { lock.withLock { _pagineChieste } }
        set { lock.withLock { _pagineChieste = newValue } }
    }

    func searchMulti(query: String, page: Int) async throws -> TMDBMultiResponse {
        // Registrazione e lettura in un solo giro di lock: se fossero due, fra l'append e la
        // lettura potrebbe infilarsi il `pages =` della riga successiva di un test.
        let entry = lock.withLock { () -> (results: [SearchResult], totalPages: Int) in
            _pagineChieste.append(page)
            return _pages[page] ?? (results: [], totalPages: page)
        }
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
