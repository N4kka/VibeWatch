import Foundation

/// Decorator trasparente su `TMDBServiceProtocol` che instrada ogni chiamata attraverso un
/// `TMDBRequestBudget` (coalescing + cache TTL breve + tetto di concorrenza). Iniettato in
/// `DiscoveryPersonalizationService` per spegnere il burst >100 richieste della generazione
/// caroselli (4.1), senza che i generatori sappiano del budget.
///
/// La `key` di ogni metodo combina nome + parametri così richieste identiche coalescono e la
/// cache non confonde tipi di ritorno diversi.
final class BudgetedTMDBService: TMDBServiceProtocol {
    private let wrapped: TMDBServiceProtocol
    private let budget: TMDBRequestBudget

    init(wrapping: TMDBServiceProtocol, maxConcurrent: Int = 6, ttl: TimeInterval = 30) {
        self.wrapped = wrapping
        self.budget = TMDBRequestBudget(maxConcurrent: maxConcurrent, ttl: ttl)
    }

    /// Svuota la cache del budget (force refresh).
    func resetBudget() async {
        await budget.reset()
    }

    /// Azzera i contatori: chiamato all'inizio di una generazione per misurarla in isolamento.
    func resetBudgetStats() async {
        await budget.resetStats()
    }

    /// Costo reale della passata appena conclusa.
    func budgetStats() async -> TMDBRequestBudget.Stats {
        await budget.currentStats()
    }

    // MARK: - Movies

    func getTrendingMovies(timeWindow: TimeWindow, page: Int) async throws -> TMDBResponse<Movie> {
        try await budget.run(key: "trendingMovies:\(timeWindow.rawValue):\(page)") { [wrapped] in
            try await wrapped.getTrendingMovies(timeWindow: timeWindow, page: page)
        }
    }

    func getPopularMovies(page: Int) async throws -> TMDBResponse<Movie> {
        try await budget.run(key: "popularMovies:\(page)") { [wrapped] in
            try await wrapped.getPopularMovies(page: page)
        }
    }

    func getTopRatedMovies(page: Int) async throws -> TMDBResponse<Movie> {
        try await budget.run(key: "topRatedMovies:\(page)") { [wrapped] in
            try await wrapped.getTopRatedMovies(page: page)
        }
    }

    func discoverMovies(
        withGenre genreId: Int?,
        sortBy: String,
        page: Int,
        minRuntime: Int?,
        maxRuntime: Int?,
        minRating: Double?,
        maxRating: Double?,
        releaseDateGte: String?,
        releaseDateLte: String?,
        country: String?
    ) async throws -> TMDBResponse<Movie> {
        let key = "discoverMovies:\(genreId?.description ?? "_"):\(sortBy):\(page):"
            + "\(minRuntime?.description ?? "_"):\(maxRuntime?.description ?? "_"):"
            + "\(minRating?.description ?? "_"):\(maxRating?.description ?? "_"):"
            + "\(releaseDateGte ?? "_"):\(releaseDateLte ?? "_"):\(country ?? "_")"
        return try await budget.run(key: key) { [wrapped] in
            try await wrapped.discoverMovies(
                withGenre: genreId, sortBy: sortBy, page: page,
                minRuntime: minRuntime, maxRuntime: maxRuntime,
                minRating: minRating, maxRating: maxRating,
                releaseDateGte: releaseDateGte, releaseDateLte: releaseDateLte, country: country
            )
        }
    }

    func searchMovies(query: String, page: Int) async throws -> TMDBResponse<Movie> {
        try await budget.run(key: "searchMovies:\(query):\(page)") { [wrapped] in
            try await wrapped.searchMovies(query: query, page: page)
        }
    }

    func getMovieDetails(id: Int) async throws -> Movie {
        try await budget.run(key: "movieDetails:\(id)") { [wrapped] in
            try await wrapped.getMovieDetails(id: id)
        }
    }

    func getMovieCredits(id: Int) async throws -> Credits {
        try await budget.run(key: "movieCredits:\(id)") { [wrapped] in
            try await wrapped.getMovieCredits(id: id)
        }
    }

    func getMovieVideos(id: Int) async throws -> TMDBVideosResponse {
        try await budget.run(key: "movieVideos:\(id)") { [wrapped] in
            try await wrapped.getMovieVideos(id: id)
        }
    }

    func getSimilarMovies(id: Int, page: Int) async throws -> TMDBResponse<Movie> {
        try await budget.run(key: "similarMovies:\(id):\(page)") { [wrapped] in
            try await wrapped.getSimilarMovies(id: id, page: page)
        }
    }

    func getMovieExternalIds(id: Int) async throws -> ExternalIds {
        try await budget.run(key: "movieExternalIds:\(id)") { [wrapped] in
            try await wrapped.getMovieExternalIds(id: id)
        }
    }

    func getMovieWatchProviders(id: Int) async throws -> WatchProvider {
        try await budget.run(key: "movieWatchProviders:\(id)") { [wrapped] in
            try await wrapped.getMovieWatchProviders(id: id)
        }
    }

    // MARK: - TV Shows

    func getTrendingTVShows(timeWindow: TimeWindow, page: Int) async throws -> TMDBResponse<TVShow> {
        try await budget.run(key: "trendingTV:\(timeWindow.rawValue):\(page)") { [wrapped] in
            try await wrapped.getTrendingTVShows(timeWindow: timeWindow, page: page)
        }
    }

    func getPopularTVShows(page: Int) async throws -> TMDBResponse<TVShow> {
        try await budget.run(key: "popularTV:\(page)") { [wrapped] in
            try await wrapped.getPopularTVShows(page: page)
        }
    }

    func getTopRatedTVShows(page: Int) async throws -> TMDBResponse<TVShow> {
        try await budget.run(key: "topRatedTV:\(page)") { [wrapped] in
            try await wrapped.getTopRatedTVShows(page: page)
        }
    }

    func discoverTVShows(
        withGenre genreId: Int?,
        sortBy: String,
        page: Int,
        minRating: Double?,
        maxRating: Double?,
        firstAirDateGte: String?,
        firstAirDateLte: String?,
        country: String?
    ) async throws -> TMDBResponse<TVShow> {
        let key = "discoverTV:\(genreId?.description ?? "_"):\(sortBy):\(page):"
            + "\(minRating?.description ?? "_"):\(maxRating?.description ?? "_"):"
            + "\(firstAirDateGte ?? "_"):\(firstAirDateLte ?? "_"):\(country ?? "_")"
        return try await budget.run(key: key) { [wrapped] in
            try await wrapped.discoverTVShows(
                withGenre: genreId, sortBy: sortBy, page: page,
                minRating: minRating, maxRating: maxRating,
                firstAirDateGte: firstAirDateGte, firstAirDateLte: firstAirDateLte, country: country
            )
        }
    }

    func searchTVShows(query: String, page: Int) async throws -> TMDBResponse<TVShow> {
        try await budget.run(key: "searchTV:\(query):\(page)") { [wrapped] in
            try await wrapped.searchTVShows(query: query, page: page)
        }
    }

    func getTVShowDetails(id: Int) async throws -> TVShow {
        try await budget.run(key: "tvDetails:\(id)") { [wrapped] in
            try await wrapped.getTVShowDetails(id: id)
        }
    }

    func getTVShowCredits(id: Int) async throws -> Credits {
        try await budget.run(key: "tvCredits:\(id)") { [wrapped] in
            try await wrapped.getTVShowCredits(id: id)
        }
    }

    func getTVShowVideos(id: Int) async throws -> TMDBVideosResponse {
        try await budget.run(key: "tvVideos:\(id)") { [wrapped] in
            try await wrapped.getTVShowVideos(id: id)
        }
    }

    func getSimilarTVShows(id: Int, page: Int) async throws -> TMDBResponse<TVShow> {
        try await budget.run(key: "similarTV:\(id):\(page)") { [wrapped] in
            try await wrapped.getSimilarTVShows(id: id, page: page)
        }
    }

    func getTVSeasonDetails(showId: Int, seasonNumber: Int) async throws -> SeasonDetail {
        try await budget.run(key: "tvSeason:\(showId):\(seasonNumber)") { [wrapped] in
            try await wrapped.getTVSeasonDetails(showId: showId, seasonNumber: seasonNumber)
        }
    }

    func getTVShowExternalIds(id: Int) async throws -> ExternalIds {
        try await budget.run(key: "tvExternalIds:\(id)") { [wrapped] in
            try await wrapped.getTVShowExternalIds(id: id)
        }
    }

    func getTVShowWatchProviders(id: Int) async throws -> WatchProvider {
        try await budget.run(key: "tvWatchProviders:\(id)") { [wrapped] in
            try await wrapped.getTVShowWatchProviders(id: id)
        }
    }

    // MARK: - Multi / People

    func searchMulti(query: String, page: Int) async throws -> TMDBMultiResponse {
        try await budget.run(key: "searchMulti:\(query):\(page)") { [wrapped] in
            try await wrapped.searchMulti(query: query, page: page)
        }
    }

    func getPersonDetails(id: Int) async throws -> PersonDetails {
        try await budget.run(key: "personDetails:\(id)") { [wrapped] in
            try await wrapped.getPersonDetails(id: id)
        }
    }

    func getPersonCombinedCredits(id: Int) async throws -> PersonCombinedCredits {
        try await budget.run(key: "personCredits:\(id)") { [wrapped] in
            try await wrapped.getPersonCombinedCredits(id: id)
        }
    }

    func searchPerson(query: String) async throws -> [PersonSearchResult] {
        try await budget.run(key: "searchPerson:\(query)") { [wrapped] in
            try await wrapped.searchPerson(query: query)
        }
    }
}
